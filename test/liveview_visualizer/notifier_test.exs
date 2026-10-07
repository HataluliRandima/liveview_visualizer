defmodule LiveViewVisualizer.NotifierTest do
  use ExUnit.Case, async: false

  import LiveViewVisualizer.SupervisionHelpers

  alias LiveViewVisualizer.{Collector, Event, Notifier, Store}

  setup do
    Store.clear()
    :ok
  end

  test "the PubSub server is part of the supervision tree" do
    assert Process.whereis(LiveViewVisualizer.PubSub)
  end

  test "recording an event broadcasts only its id" do
    :ok = Notifier.subscribe()
    event = Event.new!(type: :test, name: :notify, metadata: %{big: String.duplicate("x", 100)})

    :ok = Collector.collect(event)

    assert_receive {:event_recorded, id}
    assert id == event.id
  end

  test "events that are not stored are not announced" do
    :ok = Notifier.subscribe()
    stop_child(Store)

    {:error, :not_running} = Collector.collect(Event.new!(type: :test, name: :lost))

    refute_receive {:event_recorded, _}
  end

  test "clearing the store is announced" do
    :ok = Notifier.subscribe()
    :ok = LiveViewVisualizer.clear_events()
    assert_receive :events_cleared
  end

  test "notifying is a no-op when the PubSub server is not running" do
    stop_child(LiveViewVisualizer.PubSub)

    assert Notifier.subscribe() == {:error, :not_running}
    assert Notifier.event_recorded(1) == :ok
    assert Collector.collect(Event.new!(type: :test, name: :quiet)) == :ok
    assert [%Event{name: :quiet}] = Store.recent()
  end
end
