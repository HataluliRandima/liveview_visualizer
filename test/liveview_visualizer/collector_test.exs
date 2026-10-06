defmodule LiveViewVisualizer.CollectorTest do
  use ExUnit.Case, async: false

  import LiveViewVisualizer.SupervisionHelpers

  alias LiveViewVisualizer.{Collector, Event, Sanitizer, Store}

  setup do
    Store.clear()
    :ok
  end

  test "sanitizes metadata and measurements before storing" do
    event =
      Event.new!(
        type: :test,
        name: :collect,
        measurements: %{duration: 5, label: "dropped"},
        metadata: %{params: %{"password" => "hunter2", "name" => "Ada"}, user: %URI{}}
      )

    assert Collector.collect(event) == :ok

    assert [stored] = Store.recent()
    assert stored.id == event.id
    assert stored.measurements == %{duration: 5}

    assert stored.metadata == %{
             params: %{"password" => :redacted, "name" => "Ada"},
             user: {:struct, URI}
           }
  end

  test "uses the given sanitizer" do
    event = Event.new!(type: :test, name: :collect, metadata: %{ssn: "123"})

    Collector.collect(event, Sanitizer.new(redact_keys: [:ssn]))

    assert [%{metadata: %{ssn: :redacted}}] = Store.recent()
  end

  test "collects lists of events in order" do
    events = for i <- 1..3, do: Event.new!(type: :test, name: :collect, metadata: %{i: i})

    assert Collector.collect(events) == :ok
    assert Enum.map(Store.recent(), & &1.id) == Enum.map(events, & &1.id)
  end

  test ":ignore stores nothing" do
    assert Collector.collect(:ignore) == :ok
    assert Store.recent() == []
  end

  test "rejects input that is not an event" do
    assert Collector.collect(%{type: :test}) == {:error, {:invalid_event, %{type: :test}}}
    assert Collector.collect([:oops]) == {:error, {:invalid_event, :oops}}
    assert Store.recent() == []
  end

  test "reports when the store is not running without raising" do
    stop_child(Store)

    assert Collector.collect(Event.new!(type: :test, name: :collect)) == {:error, :not_running}
  end
end
