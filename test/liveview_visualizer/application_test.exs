defmodule LiveViewVisualizer.ApplicationTest do
  use ExUnit.Case, async: false

  import LiveViewVisualizer.SupervisionHelpers

  alias LiveViewVisualizer.{Event, Store, Telemetry}

  @app :liveview_visualizer

  describe "when enabled" do
    test "starts the store, notifications and telemetry under the visualizer supervisor, in order" do
      children = Supervisor.which_children(LiveViewVisualizer.Supervisor)

      # which_children/1 lists children in reverse start order.
      assert [
               {Telemetry, telemetry_pid, :worker, _},
               {LiveViewVisualizer.PubSub, pubsub_pid, :supervisor, _},
               {Store, store_pid, :worker, _}
             ] = children

      assert Process.alive?(store_pid)
      assert Process.alive?(pubsub_pid)
      assert Process.alive?(telemetry_pid)
      assert :ets.whereis(Store) != :undefined
    end

    test "a store crash does not restart the telemetry process" do
      telemetry_pid = Process.whereis(Telemetry)
      store_pid = Process.whereis(Store)

      Process.exit(store_pid, :kill)
      await_restart(Store, store_pid)

      assert Process.whereis(Telemetry) == telemetry_pid
    end

    test "the public API records and returns events end to end" do
      LiveViewVisualizer.clear_events()

      :ok = LiveViewVisualizer.Collector.collect(Event.new!(type: :test, name: :e2e))

      assert [%Event{name: :e2e}] = LiveViewVisualizer.recent_events()
      assert [%Event{name: :e2e}] = LiveViewVisualizer.recent_events(1)
      assert LiveViewVisualizer.clear_events() == :ok
      assert LiveViewVisualizer.recent_events() == []
    end
  end

  describe "when disabled" do
    setup do
      :ok = Application.stop(@app)
      Application.put_env(@app, :enabled, false)

      on_exit(fn ->
        Application.stop(@app)
        Application.put_env(@app, :enabled, true)
        {:ok, _} = Application.ensure_all_started(@app)
      end)

      {:ok, _} = Application.ensure_all_started(@app)
      :ok
    end

    test "starts no processes, creates no table and attaches no handlers" do
      refute LiveViewVisualizer.enabled?()
      assert Supervisor.which_children(LiveViewVisualizer.Supervisor) == []
      assert Process.whereis(Store) == nil
      assert Process.whereis(Telemetry) == nil
      assert :ets.whereis(Store) == :undefined

      visualizer_handlers =
        for %{id: {Telemetry, _}} = handler <- :telemetry.list_handlers([]), do: handler

      assert visualizer_handlers == []
    end

    test "the public API is a safe no-op" do
      assert Store.record(Event.new!(type: :test, name: :noop)) == {:error, :not_running}
      assert LiveViewVisualizer.recent_events() == []
      assert LiveViewVisualizer.clear_events() == :ok
      assert Telemetry.attach(LiveViewVisualizer.TestInstrumentation) == {:error, :not_running}
    end
  end
end
