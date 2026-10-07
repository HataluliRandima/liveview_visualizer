defmodule LiveViewVisualizer.Store do
  @moduledoc """
  Bounded, in-memory storage for recent events.

  Events are kept in a public ETS table that works as a fixed-size ring buffer:

    * A single counter row `{:seq, last_seq, capacity}` is incremented atomically
      with `:ets.update_counter/3` for every write. The same call returns the
      capacity, so a write needs no extra lookup.
    * The event with sequence number `seq` is stored in slot
      `rem(seq - 1, capacity)` as `{slot, seq, event}`, overwriting whatever was
      there before. Memory is therefore bounded by `capacity` events, and each
      event's size is bounded by `LiveViewVisualizer.Sanitizer`.

  Writes go straight to ETS from the calling process instead of through this
  GenServer. Telemetry handlers run inside the observed processes (for example
  each LiveView), so routing writes through one process would serialize them
  and turn the visualizer into a bottleneck. The table uses
  `write_concurrency` and `read_concurrency` for the same reason.

  This GenServer only owns the table. If it crashes the table disappears until
  the supervisor restarts it. Writes in that window are dropped with
  `{:error, :not_running}` and never raise.

  ## Consistency

  Reads are lock-free and therefore best-effort under concurrent writes. A
  reader may skip an event whose slot is being overwritten at that moment, and
  if two writers exactly `capacity` sequence numbers apart race for the same
  slot, the older event can win and the newer one is skipped by readers. That
  is acceptable for a development tool and keeps writes to two ETS operations.
  """

  use GenServer

  alias LiveViewVisualizer.{Config, Event}

  @table __MODULE__

  @doc """
  Starts the store.

  ## Options

    * `:max_events` - the ring buffer capacity. Defaults to
      `LiveViewVisualizer.Config.max_events/0`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores an event, overwriting the oldest one when the store is full.

  Callers are responsible for sanitizing the event first. Normally that happens
  in `LiveViewVisualizer.Collector`.

  Returns `{:error, :not_running}` instead of raising when the store is not
  started, for example when the visualizer is disabled.
  """
  @spec record(Event.t()) :: :ok | {:error, :not_running}
  def record(%Event{} = event) do
    [seq, capacity] = :ets.update_counter(@table, :seq, [{2, 1}, {3, 0}])
    true = :ets.insert(@table, {rem(seq - 1, capacity), seq, event})
    :ok
  rescue
    ArgumentError -> {:error, :not_running}
  end

  @doc """
  Returns up to `limit` of the most recent events, oldest first.

  With no limit, every retained event is returned. Returns `[]` if the store is
  empty or not running.
  """
  @spec recent(pos_integer() | nil) :: [Event.t()]
  def recent(limit \\ nil) when is_nil(limit) or (is_integer(limit) and limit > 0) do
    [{:seq, last_seq, capacity}] = :ets.lookup(@table, :seq)

    count = (limit || capacity) |> min(capacity) |> min(last_seq)

    # A slot whose stored sequence number differs from the expected one has
    # already been overwritten (or cleared), so the pinned pattern skips it.
    for seq <- (last_seq - count + 1)..last_seq//1,
        {_slot, ^seq, event} <- :ets.lookup(@table, rem(seq - 1, capacity)),
        do: event
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the events recorded after sequence number `after_seq`, oldest first,
  together with the latest sequence number.

  Lets a reader such as the dashboard fetch only what is new: pass `0` the
  first time, then the returned sequence number. Only events still retained
  are returned, so after a long gap this returns at most `capacity/0` events.

  A returned sequence number lower than `after_seq` means the store restarted.
  Returns `{0, []}` if the store is not running.
  """
  @spec since(non_neg_integer()) :: {non_neg_integer(), [Event.t()]}
  def since(after_seq) when is_integer(after_seq) and after_seq >= 0 do
    [{:seq, last_seq, capacity}] = :ets.lookup(@table, :seq)
    first = max(after_seq + 1, last_seq - capacity + 1)

    events =
      for seq <- first..last_seq//1,
          {_slot, ^seq, event} <- :ets.lookup(@table, rem(seq - 1, capacity)),
          do: event

    {last_seq, events}
  rescue
    ArgumentError -> {0, []}
  end

  @doc """
  Removes all stored events.

  Sequence numbers are not reset, so events recorded concurrently with a clear
  are never confused with older ones.
  """
  @spec clear() :: :ok
  def clear do
    :ets.select_delete(@table, [{{:"$1", :_, :_}, [{:is_integer, :"$1"}], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the number of events currently stored, or `0` if the store is not running.
  """
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size - 1
    end
  end

  @doc """
  Returns the maximum number of events the store retains, or `nil` if it is not running.
  """
  @spec capacity() :: pos_integer() | nil
  def capacity do
    :ets.lookup_element(@table, :seq, 3)
  rescue
    ArgumentError -> nil
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get_lazy(opts, :max_events, &Config.max_events/0)

    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    true = :ets.insert(table, {:seq, 0, capacity})

    {:ok, %{table: table, capacity: capacity}}
  end
end
