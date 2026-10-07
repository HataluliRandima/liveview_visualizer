defmodule LiveViewVisualizer.Context do
  @moduledoc """
  Process-local tracking of the lifecycle operation currently executing.

  Internal to the visualizer. It lets an event that happens *inside* a
  LiveView callback, such as an Ecto query, name that callback as its parent.

  ## How it works

  `:telemetry.span/3` emits `:start` and then `:stop` or `:exception` in the
  same process, around the callback. All three carry the same
  `telemetry_span_context`. On `:start`, `enter/1` pushes an entry onto a small
  stack in the process dictionary. On `:stop`/`:exception`, `exit/1` removes the
  entry with that span context. Anything that runs in between in the same
  process sees the entry through `current/0`.

  Because spans in one process are strictly nested, the top of the stack is
  always the innermost running callback. This is a real relationship, not a
  guess based on timing.

  ## Safety

    * **Bounded.** At most 8 entries. Deeper nesting is not tracked, so its
      children get no parent rather than a wrong one.
    * **Restored.** `exit/1` deletes the process dictionary key once the stack
      is empty, so nothing remains in the process between callbacks.
    * **Exception-safe.** Telemetry emits `:exception` (which calls `exit/1`)
      for raises, throws and exits. A killed process takes its dictionary with
      it.
    * **Generation-aware.** If handlers are detached mid-span, the matching
      `exit/1` never runs and the entry would linger. Every entry records the
      epoch it was created in, and `bump_epoch/0` is called whenever handlers
      are attached or detached. `current/0` treats entries from an older epoch
      as stale: it returns `nil` and clears them.
    * **Same process only.** Other processes (Tasks, GenServers, Oban jobs)
      never see this context. Their events have no parent, because there is no
      reliable way to know whether the spawning callback is still running.
  """

  alias LiveViewVisualizer.Event

  @key {__MODULE__, :stack}
  @epoch_key {__MODULE__, :epoch}
  @max_depth 8

  # {span_context, id, parent_id, trace_id, epoch}
  @typep entry :: {term(), Event.id(), Event.id() | nil, Event.id(), non_neg_integer()}

  @typedoc "Identifiers to put on an event."
  @type ids :: %{id: Event.id(), parent_id: Event.id() | nil, trace_id: Event.id() | nil}

  @doc """
  Advances the epoch, invalidating every entry currently on any process's stack.

  Creates the epoch counter on first use. The counter is stored once in
  `:persistent_term` and never replaced, so later bumps are a single atomic
  increment.
  """
  @spec bump_epoch() :: :ok
  def bump_epoch do
    counter =
      case :persistent_term.get(@epoch_key, nil) do
        nil ->
          counter = :atomics.new(1, signed: false)
          :persistent_term.put(@epoch_key, counter)
          counter

        counter ->
          counter
      end

    :atomics.add(counter, 1, 1)
  end

  @doc """
  Records that the span identified by `span_context` started in this process.

  Returns the ids its event will carry. `id` is allocated now so that events
  occurring during the span can reference it. `trace_id` is the id of the
  outermost tracked span.
  """
  @spec enter(term()) :: ids()
  def enter(span_context) do
    id = Event.new_id()

    case epoch() do
      nil ->
        %{id: id, parent_id: nil, trace_id: id}

      epoch ->
        stack = valid_stack(epoch)

        {parent_id, trace_id} =
          case stack do
            [{_, enclosing_id, _, trace_id, _} | _] -> {enclosing_id, trace_id}
            [] -> {nil, id}
          end

        if length(stack) < @max_depth do
          Process.put(@key, [{span_context, id, parent_id, trace_id, epoch} | stack])
        end

        %{id: id, parent_id: parent_id, trace_id: trace_id}
    end
  end

  @doc """
  Records that the span identified by `span_context` ended in this process.

  Returns the ids allocated by `enter/1`, or `nil` if the start was not seen
  (for example because handlers were attached mid-span). Entries above the
  matching one belong to spans whose end was missed and are discarded too.
  """
  @spec exit(term()) :: ids() | nil
  def exit(span_context) do
    stack = Process.get(@key, [])

    case Enum.split_while(stack, &(elem(&1, 0) !== span_context)) do
      {_, []} ->
        nil

      {_missed, [{_, id, parent_id, trace_id, _} | rest]} ->
        store(rest)
        %{id: id, parent_id: parent_id, trace_id: trace_id}
    end
  end

  @doc """
  Returns the innermost span currently running in this process, as the
  `parent_id` and `trace_id` for an event happening inside it, or `nil`.
  """
  @spec current() :: %{parent_id: Event.id(), trace_id: Event.id()} | nil
  def current do
    with [_ | _] <- Process.get(@key),
         epoch when is_integer(epoch) <- epoch(),
         [{_, id, _, trace_id, _} | _] <- valid_stack(epoch) do
      %{parent_id: id, trace_id: trace_id}
    else
      _ -> nil
    end
  end

  # Returns this process's stack, clearing it if it was created in an older epoch.
  @spec valid_stack(non_neg_integer()) :: [entry()]
  defp valid_stack(epoch) do
    case Process.get(@key) do
      nil ->
        []

      [{_, _, _, _, ^epoch} | _] = stack ->
        stack

      _stale ->
        Process.delete(@key)
        []
    end
  end

  defp store([]), do: Process.delete(@key)
  defp store(stack), do: Process.put(@key, stack)

  defp epoch do
    case :persistent_term.get(@epoch_key, nil) do
      nil -> nil
      counter -> :atomics.get(counter, 1)
    end
  end
end
