defmodule LiveViewVisualizer.Instrumentation.LiveViewIntegrationTest do
  # Drives real LiveViews through Phoenix.LiveViewTest and checks what the
  # automatically attached instrumentation records. Uses the shared store.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import LiveViewVisualizer.SupervisionHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewVisualizer.{Event, Store, Telemetry}
  alias LiveViewVisualizer.Instrumentation.LiveView, as: Instrumentation
  alias LiveViewVisualizer.TestApp

  @endpoint TestApp.Endpoint
  @app :liveview_visualizer

  setup do
    Store.clear()
    {:ok, conn: build_conn()}
  end

  defp events_for(module) do
    Enum.filter(Store.recent(), &(&1.module == module or &1.metadata[:view] == module))
  end

  defp names(events), do: Enum.map(events, &{&1.type, &1.name})

  defp version_at_least?(version),
    do: Version.compare(Instrumentation.live_view_version(), version) != :lt

  describe "automatic attachment" do
    test "the LiveView instrumentation is attached without any configuration" do
      assert Instrumentation in Telemetry.attached()

      handler_ids = fn event ->
        event
        |> :telemetry.list_handlers()
        |> Enum.filter(&(&1.event_name == event))
        |> Enum.map(& &1.id)
      end

      assert {Telemetry, Instrumentation} in handler_ids.([:phoenix, :live_view, :mount, :stop])

      assert {Telemetry, Instrumentation} in handler_ids.([
               :phoenix,
               :live_view,
               :mount,
               :exception
             ])

      # :start is attached for correlation (see LiveViewVisualizer.Context).
      assert {Telemetry, Instrumentation} in handler_ids.([:phoenix, :live_view, :mount, :start])
    end
  end

  describe "LiveView lifecycle" do
    test "records mount, render, handle_event and render in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter")
      assert render_click(view, "inc") =~ "Count: 1"

      events = events_for(TestApp.CounterLive)

      assert names(events) == [
               # disconnected (HTTP) render: LiveView emits no render span for it
               {:live_view, :mount},
               {:live_view, :handle_params},
               # connected render
               {:live_view, :mount},
               {:live_view, :handle_params},
               {:live_view, :render},
               {:live_view, :handle_event},
               {:live_view, :render}
             ]

      assert Enum.map(events, & &1.metadata[:connected?]) ==
               [false, false, true, true, nil, nil, nil]

      for event <- events do
        assert event.module == TestApp.CounterLive
        assert event.status == :ok
        assert is_integer(event.duration) and event.duration >= 0
        assert event.metadata.view == TestApp.CounterLive
        assert event.source |> List.last() == :stop
      end

      # The connected events come from the LiveView process itself.
      connected = Enum.drop(events, 2)
      assert Enum.all?(connected, &(&1.pid == view.pid))

      # All events belong to the same LiveView instance.
      assert events |> Enum.map(& &1.metadata.socket_id) |> Enum.uniq() |> length() == 1

      # Events are stored in completion order, which matches start order here.
      starts = Enum.map(events, & &1.monotonic_time)
      assert starts == Enum.sort(starts)

      handle_event = Enum.find(events, &(&1.name == :handle_event))
      assert handle_event.metadata.event == "inc"
      assert hd(events).metadata.route == "/counter"
    end

    test "captures every interaction in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter")
      Store.clear()

      for _ <- 1..3, do: render_click(view, "inc")

      events = events_for(TestApp.CounterLive)

      assert names(events) ==
               List.flatten(
                 List.duplicate([{:live_view, :handle_event}, {:live_view, :render}], 3)
               )

      assert Enum.map(events, & &1.id) == Enum.sort(Enum.map(events, & &1.id))
    end

    test "records live component update, handle_event, render and destroy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/components")

      assert view |> element("#counter-component") |> render_click() =~ "Component: 1"
      refute render_click(view, "hide") =~ "Component:"
      # The client acknowledges the removal asynchronously; render/1 syncs with it.
      render(view)

      component_events = Enum.filter(Store.recent(), &(&1.type == :live_component))
      assert Enum.all?(component_events, &(&1.module == TestApp.CounterComponent))
      assert Enum.all?(component_events, &(&1.metadata.view == TestApp.ComponentsLive))
      assert Enum.all?(component_events, &is_integer(&1.metadata.cid))

      expected =
        [{:live_component, :update}, {:live_component, :update}, {:live_component, :handle_event}] ++
          if(version_at_least?("1.2.0"), do: [{:live_component, :render}], else: []) ++
          if(version_at_least?("1.1.0"), do: [{:live_component, :destroyed}], else: [])

      assert names(component_events) == expected

      handle_event = Enum.find(component_events, &(&1.name == :handle_event))
      assert handle_event.metadata.event == "inc"
    end
  end

  describe "sensitive data" do
    test "session, params, assigns and URL secrets never reach the store" do
      conn =
        Plug.Test.init_test_session(build_conn(), %{
          "password" => "session-hunter2",
          "user_token" => "session-tok"
        })

      {:ok, view, _html} = live(conn, "/counter?password=query-hunter2&api_key=query-key")
      render_click(view, "inc", %{"password" => "event-hunter2"})

      {:ok, reset, _html} = live(build_conn(), "/reset/path-reset-token")
      reset |> form("#reset", %{password: "form-hunter2"}) |> render_submit()

      events = Store.recent()
      assert events != []

      stored = inspect(events, limit: :infinity, printable_limit: :infinity)

      for secret <-
            ~w(session-hunter2 session-tok query-hunter2 query-key event-hunter2 path-reset-token form-hunter2) do
        refute stored =~ secret, "#{secret} leaked into the store"
      end

      allowed =
        ~w(view component cid socket_id connected? route event changed? force? count kind exception)a

      for event <- events do
        assert event.metadata |> Map.keys() |> Enum.all?(&(&1 in allowed)),
               "unexpected metadata keys: #{inspect(Map.keys(event.metadata))}"
      end

      assert Enum.any?(events, &(&1.metadata[:route] == "/reset/:token"))
    end

    test "dangerous raw metadata on real LiveView event names is not stored" do
      metadata = %{
        socket: %Phoenix.LiveView.Socket{
          view: TestApp.CounterLive,
          assigns: %{secret: "socket-secret"}
        },
        session: %{password: "session-secret"},
        params: %{password: "params-secret"},
        uri: "http://localhost/counter?token=uri-secret"
      }

      :telemetry.execute(
        [:phoenix, :live_view, :mount, :stop],
        %{duration: 5, monotonic_time: 0},
        metadata
      )

      assert [%Event{name: :mount} = event] = Store.recent()

      for secret <- ~w(socket-secret session-secret params-secret uri-secret) do
        refute inspect(event, limit: :infinity) =~ secret
      end
    end
  end

  describe "exceptions" do
    defp crash_in_handle_event do
      {:ok, view, _html} = live(build_conn(), "/crash")
      Process.flag(:trap_exit, true)
      {reason, _log} = with_log(fn -> catch_exit(render_click(view, "boom")) end)
      reason
    end

    test "a raising handle_event is recorded with status :exception" do
      crash_in_handle_event()

      assert [%Event{} = event] =
               Enum.filter(events_for(TestApp.CrashLive), &(&1.name == :handle_event))

      assert event.status == :exception
      assert event.source == [:phoenix, :live_view, :handle_event, :exception]
      assert event.metadata.event == "boom"
      assert event.metadata.kind == :error
      assert event.metadata.exception == RuntimeError
      assert is_integer(event.duration)
      refute inspect(event) =~ "boom from handle_event"
    end

    test "a raising mount is recorded with status :exception" do
      assert_raise ArgumentError, "boom from mount", fn -> live(build_conn(), "/crash-mount") end

      assert [%Event{name: :mount, status: :exception} = event] =
               events_for(TestApp.CrashMountLive)

      assert event.metadata.exception == ArgumentError
      assert event.metadata.connected? == false
    end

    test "LiveView failure behaviour is identical with and without the visualizer" do
      observed = crash_in_handle_event()

      :ok = Telemetry.detach(Instrumentation)
      on_exit(fn -> Telemetry.attach(Instrumentation) end)

      unobserved = crash_in_handle_event()

      assert {{%RuntimeError{} = observed_error, _}, _} = observed
      assert {{%RuntimeError{} = unobserved_error, _}, _} = unobserved
      assert observed_error == unobserved_error

      assert_raise ArgumentError, "boom from mount", fn -> live(build_conn(), "/crash-mount") end
    end
  end

  describe "failure isolation" do
    test "LiveViews keep working when the store is down", %{conn: conn} do
      stop_child(Store)

      log =
        capture_log(fn ->
          {:ok, view, _html} = live(conn, "/counter")
          assert render_click(view, "inc") =~ "Count: 1"
        end)

      assert log == ""
      assert Instrumentation in Telemetry.attached()
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

    test "no handlers are attached and nothing is recorded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/counter")
      assert render_click(view, "inc") =~ "Count: 1"

      visualizer_handlers =
        for %{id: {Telemetry, _}} = handler <- :telemetry.list_handlers([:phoenix]), do: handler

      assert visualizer_handlers == []
      assert Process.whereis(Store) == nil
      assert :ets.whereis(Store) == :undefined
      assert LiveViewVisualizer.recent_events() == []
    end
  end
end
