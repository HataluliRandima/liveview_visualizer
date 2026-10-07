defmodule LiveViewVisualizer.Collector do
  @moduledoc """
  The single path through which observed events reach the store.

  Instrumentations produce `LiveViewVisualizer.Event` structs. The collector
  sanitizes their metadata and measurements, records them, and announces each
  stored event through `LiveViewVisualizer.Notifier`. Keeping this in one place
  guarantees that nothing is stored unsanitized, whatever the source.

  The collector runs inside the observed process, for example a LiveView's
  process when called from a telemetry handler, so it does as little work as
  possible and never raises for well-formed input.
  """

  alias LiveViewVisualizer.{Event, Notifier, Sanitizer, Store}

  @typedoc "What an instrumentation may hand to the collector."
  @type input :: Event.t() | [Event.t()] | :ignore

  @doc """
  Sanitizes and stores the given event or events.

  `:ignore` is accepted and does nothing, so instrumentations can skip telemetry
  events they are not interested in.

  Returns `{:error, :not_running}` if the store is not running, and
  `{:error, {:invalid_event, term}}` for input that is not an event.
  """
  @spec collect(input(), Sanitizer.t()) ::
          :ok | {:error, :not_running | {:invalid_event, term()}}
  def collect(input, sanitizer \\ %Sanitizer{})

  def collect(:ignore, _sanitizer), do: :ok

  def collect(%Event{} = event, sanitizer) do
    with :ok <- event |> sanitize(sanitizer) |> Store.record() do
      Notifier.event_recorded(event.id)
    end
  end

  def collect(events, sanitizer) when is_list(events) do
    Enum.reduce(events, :ok, fn event, acc ->
      case collect(event, sanitizer) do
        :ok -> acc
        error -> error
      end
    end)
  end

  def collect(other, _sanitizer), do: {:error, {:invalid_event, other}}

  defp sanitize(%Event{} = event, sanitizer) do
    %Event{
      event
      | metadata: Sanitizer.sanitize_metadata(event.metadata, sanitizer),
        measurements: Sanitizer.sanitize_measurements(event.measurements)
    }
  end
end
