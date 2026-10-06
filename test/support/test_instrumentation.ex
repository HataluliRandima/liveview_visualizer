defmodule LiveViewVisualizer.TestInstrumentation do
  @moduledoc false
  # An instrumentation whose behaviour is selected by the telemetry event name,
  # so tests can exercise success, skip and every failure mode.

  @behaviour LiveViewVisualizer.Instrumentation

  alias LiveViewVisualizer.Event

  @impl true
  def events do
    [
      [:lvv_test, :work, :stop],
      [:lvv_test, :many],
      [:lvv_test, :ignore],
      [:lvv_test, :raise],
      [:lvv_test, :throw],
      [:lvv_test, :exit],
      [:lvv_test, :bad_return]
    ]
  end

  @impl true
  def handle_event([:lvv_test, :work, :stop] = source, measurements, metadata) do
    Event.new!(
      type: :test,
      name: :work,
      source: source,
      duration: measurements.duration,
      measurements: measurements,
      # Deliberately unfiltered so tests can verify the collector sanitizes it.
      metadata: metadata
    )
  end

  def handle_event([:lvv_test, :many], %{count: count}, _metadata) do
    for i <- 1..count, do: Event.new!(type: :test, name: :many, metadata: %{i: i})
  end

  def handle_event([:lvv_test, :ignore], _measurements, _metadata), do: :ignore

  # Raises a KeyError whose message would include the metadata, to verify
  # that failure logging never leaks it.
  def handle_event([:lvv_test, :raise], _measurements, metadata),
    do: Map.fetch!(metadata, :missing)

  def handle_event([:lvv_test, :throw], _measurements, _metadata), do: throw(:boom)
  def handle_event([:lvv_test, :exit], _measurements, _metadata), do: exit(:boom)
  def handle_event([:lvv_test, :bad_return], _measurements, _metadata), do: {:not, :an_event}
end

defmodule LiveViewVisualizer.EmptyInstrumentation do
  @moduledoc false
  # Simulates an instrumentation whose library is not available.
  @behaviour LiveViewVisualizer.Instrumentation

  @impl true
  def events, do: []

  @impl true
  def handle_event(_event, _measurements, _metadata), do: :ignore
end
