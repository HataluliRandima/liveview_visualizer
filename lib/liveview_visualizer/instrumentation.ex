defmodule LiveViewVisualizer.Instrumentation do
  @moduledoc """
  Behaviour for a source of observed events.

  An instrumentation declares which `:telemetry` events it listens to and how to
  turn each of them into `LiveViewVisualizer.Event` structs.
  `LiveViewVisualizer.Telemetry` attaches the handlers and passes the results to
  `LiveViewVisualizer.Collector`.

  Adding support for a new library (LiveView, Ecto, PubSub, ...) means adding a
  module that implements this behaviour. The store, the collector and the
  telemetry plumbing stay unchanged.

  ## Example

      defmodule MyInstrumentation do
        @behaviour LiveViewVisualizer.Instrumentation

        alias LiveViewVisualizer.Event

        @impl true
        def events, do: [[:my_lib, :work, :stop]]

        @impl true
        def handle_event([:my_lib, :work, :stop] = source, %{duration: duration}, metadata) do
          case Event.new(
                 type: :my_lib,
                 name: :work,
                 source: source,
                 duration: duration,
                 monotonic_time: System.monotonic_time() - duration,
                 system_time: System.system_time() - duration,
                 metadata: Map.take(metadata, [:job])
               ) do
            {:ok, event} -> event
            {:error, _reason} -> :ignore
          end
        end
      end

  ## Guidelines

    * `c:handle_event/3` runs synchronously inside the process that emitted the
      telemetry event, which is often a LiveView process serving a user. Keep it
      fast and do not block or call other processes.
    * Copy only the metadata you need (`Map.take/2`) instead of storing raw
      telemetry metadata. Raw metadata often contains whole sockets, sessions
      and params. Everything is still passed through
      `LiveViewVisualizer.Sanitizer`, but allowlisting is the first defence.
    * Do not raise. If it does happen, `LiveViewVisualizer.Telemetry` catches the
      error, drops the event, logs once and keeps the handler attached.
    * Handle version differences of the instrumented library in `c:events/0`, for
      example by returning `[]` when the library is not loaded or is unsupported.
  """

  alias LiveViewVisualizer.Event

  @doc """
  Returns the `:telemetry` event names to attach to.

  Return `[]` when the instrumented library is not available. The
  instrumentation is then skipped.
  """
  @callback events() :: [:telemetry.event_name()]

  @doc """
  Converts one telemetry event into zero or more events.

  Return `:ignore` to skip the telemetry event.

  Return `{:attach, event_names}` to have more telemetry events attached to
  this instrumentation, for event names that are only discovered at runtime
  (see `LiveViewVisualizer.Instrumentation.Ecto`). They are attached before the
  handler returns. Already attached names are ignored.
  """
  @callback handle_event(
              event_name :: :telemetry.event_name(),
              measurements :: :telemetry.event_measurements(),
              metadata :: :telemetry.event_metadata()
            ) :: Event.t() | [Event.t()] | :ignore | {:attach, [:telemetry.event_name()]}
end
