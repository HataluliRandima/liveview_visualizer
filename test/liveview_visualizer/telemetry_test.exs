defmodule LiveViewVisualizer.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import LiveViewVisualizer.SupervisionHelpers

  alias LiveViewVisualizer.{EmptyInstrumentation, Event, Store, Telemetry, TestInstrumentation}

  @app :liveview_visualizer
  @handler_id {Telemetry, TestInstrumentation}

  setup do
    Store.clear()
    :ok = Telemetry.attach(TestInstrumentation)
    on_exit(fn -> Telemetry.detach(TestInstrumentation) end)
  end

  defp handler_attached? do
    [:lvv_test, :work, :stop]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == @handler_id))
  end

  defp emit_work(metadata \\ %{}) do
    :telemetry.execute([:lvv_test, :work, :stop], %{duration: 1_000}, metadata)
  end

  describe "handling events" do
    test "a telemetry event is normalized and stored" do
      emit_work(%{job: "import"})

      assert [%Event{} = event] = Store.recent()
      assert event.type == :test
      assert event.name == :work
      assert event.source == [:lvv_test, :work, :stop]
      assert event.duration == 1_000
      assert event.measurements == %{duration: 1_000}
      assert event.metadata == %{job: "import"}
      # Handlers run in the emitting process, so that is the observed pid.
      assert event.pid == self()
    end

    test "events from other processes record those processes" do
      task = Task.async(fn -> emit_work() end)
      Task.await(task)

      assert [%Event{pid: pid}] = Store.recent()
      assert pid == task.pid
    end

    test "raw telemetry metadata is sanitized before it is stored" do
      emit_work(%{session: %{"user_token" => "abc"}, params: %{"password" => "hunter2"}})

      assert [%Event{metadata: metadata}] = Store.recent()
      assert metadata == %{session: :redacted, params: %{"password" => :redacted}}
    end

    test "instrumentations can produce several events or none" do
      :telemetry.execute([:lvv_test, :many], %{count: 3}, %{})
      :telemetry.execute([:lvv_test, :ignore], %{}, %{})

      assert Enum.map(Store.recent(), & &1.metadata.i) == [1, 2, 3]
    end
  end

  describe "failure isolation" do
    for failure <- [:raise, :throw, :exit, :bad_return] do
      test "#{failure} in an instrumentation never reaches the caller and keeps the handler attached" do
        log =
          capture_log(fn ->
            assert :telemetry.execute([:lvv_test, unquote(failure)], %{}, %{}) == :ok
          end)

        assert log =~ inspect(TestInstrumentation)
        assert log =~ "dropped"
        assert handler_attached?()
        assert Store.recent() == []

        emit_work()
        assert [%Event{name: :work}] = Store.recent()
      end
    end

    test "failures are logged once per instrumentation, without exception messages" do
      secret_metadata = %{password: "hunter2", token: "secret-token"}

      log =
        capture_log(fn ->
          for _ <- 1..5, do: :telemetry.execute([:lvv_test, :raise], %{}, secret_metadata)
        end)

      assert log =~ "KeyError"
      refute log =~ "hunter2"
      refute log =~ "secret-token"
      assert length(Regex.scan(~r/failed while handling/, log)) == 1
    end

    test "the caller process keeps running and is not linked to any failure" do
      parent = self()

      pid =
        spawn(fn ->
          capture_log(fn -> :telemetry.execute([:lvv_test, :exit], %{}, %{}) end)
          send(parent, {:still_alive, self()})
        end)

      assert_receive {:still_alive, ^pid}
    end

    test "handlers do not fail or log when the store is not running" do
      stop_child(Store)

      log = capture_log(fn -> assert emit_work() == :ok end)

      assert log == ""
      assert handler_attached?()
    end
  end

  describe "attach/1 and detach/1" do
    test "detached instrumentations no longer record events" do
      assert TestInstrumentation in Telemetry.attached()
      assert Telemetry.detach(TestInstrumentation) == :ok

      refute handler_attached?()
      refute TestInstrumentation in Telemetry.attached()

      emit_work()
      assert Store.recent() == []

      assert Telemetry.detach(TestInstrumentation) == {:error, :not_attached}
    end

    test "attaching twice replaces the handler instead of duplicating it" do
      assert Telemetry.attach(TestInstrumentation) == :ok

      emit_work()

      assert length(Store.recent()) == 1
      assert Enum.count(Telemetry.attached(), &(&1 == TestInstrumentation)) == 1
    end

    test "rejects modules that are not instrumentations" do
      assert Telemetry.attach(String) == {:error, :not_an_instrumentation}
      assert Telemetry.attach(Does.Not.Exist) == {:error, :not_an_instrumentation}
    end

    test "skips instrumentations without events" do
      assert Telemetry.attach(EmptyInstrumentation) == {:error, :no_events}
      refute EmptyInstrumentation in Telemetry.attached()
    end
  end

  describe "lifecycle" do
    test "terminating the telemetry process detaches its handlers" do
      stop_child(Telemetry)

      refute handler_attached?()
      assert Telemetry.attached() == []
      assert Telemetry.attach(TestInstrumentation) == {:error, :not_running}
    end

    test "configured instrumentations are attached on start" do
      original = Application.get_env(@app, :instrumentations)

      on_exit(fn ->
        if original,
          do: Application.put_env(@app, :instrumentations, original),
          else: Application.delete_env(@app, :instrumentations)
      end)

      Application.put_env(@app, :instrumentations, [TestInstrumentation, EmptyInstrumentation])
      stop_child(Telemetry)
      refute handler_attached?()

      restart_child(Telemetry)

      # Built-in instrumentations come first, then configured ones; the
      # EmptyInstrumentation is skipped because it declares no events.
      assert Telemetry.attached() == [
               LiveViewVisualizer.Instrumentation.LiveView,
               TestInstrumentation
             ]

      emit_work()
      assert [%Event{name: :work}] = Store.recent()
    end
  end
end
