defmodule LiveViewVisualizer.Instrumentation.LiveViewTest do
  # Unit tests for event selection and metadata extraction. The integration
  # tests in live_view_integration_test.exs drive real LiveViews.
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.Event
  alias LiveViewVisualizer.Instrumentation.LiveView, as: Instrumentation
  alias LiveViewVisualizer.TestApp
  alias Phoenix.LiveView.Socket

  @spans [
    [:phoenix, :live_view, :mount],
    [:phoenix, :live_view, :handle_params],
    [:phoenix, :live_view, :handle_event],
    [:phoenix, :live_view, :render],
    [:phoenix, :live_component, :handle_event],
    [:phoenix, :live_component, :update]
  ]

  @destroyed [:phoenix, :live_component, :destroyed]

  # A socket as LiveView passes it in telemetry metadata, full of sensitive data.
  defp socket(overrides \\ []) do
    struct!(
      %Socket{
        id: "phx-test",
        view: TestApp.CounterLive,
        router: TestApp.Router,
        transport_pid: self(),
        assigns: %{__changed__: %{}, current_user_password: "assign-secret", count: 1},
        private: %{connect_info: %{session: %{"user_token" => "private-secret"}}}
      },
      overrides
    )
  end

  defp stop(span, metadata, duration \\ 1_000) do
    Instrumentation.handle_event(
      span ++ [:stop],
      %{duration: duration, monotonic_time: System.monotonic_time()},
      metadata
    )
  end

  describe "events_for/1" do
    test "attaches :stop and :exception of every span, never :start" do
      events = Instrumentation.events_for("1.0.19")

      assert Enum.sort(events) ==
               Enum.sort(for s <- @spans, x <- [:stop, :exception], do: s ++ [x])

      refute Enum.any?(events, &(List.last(&1) == :start))
    end

    test "adds the destroyed event only from LiveView 1.1.0" do
      refute @destroyed in Instrumentation.events_for("1.0.19")
      refute @destroyed in Instrumentation.events_for("1.1.0-rc.0")
      assert @destroyed in Instrumentation.events_for("1.1.0")
      assert @destroyed in Instrumentation.events_for("1.2.12")
    end

    test "returns no events when LiveView is unavailable or the version is invalid" do
      assert Instrumentation.events_for(nil) == []
      assert Instrumentation.events_for("not-a-version") == []
    end

    test "events/0 uses the installed LiveView version" do
      installed = Application.spec(:phoenix_live_view, :vsn) |> List.to_string()

      assert Instrumentation.live_view_version() == installed
      assert Instrumentation.events() == Instrumentation.events_for(installed)
    end
  end

  describe "handle_event/3 for spans" do
    test "builds a completed :live_view event with exact native timing" do
      duration = System.convert_time_unit(1500, :microsecond, :native)
      stop_time = System.monotonic_time()

      event =
        Instrumentation.handle_event(
          [:phoenix, :live_view, :render, :stop],
          %{duration: duration, monotonic_time: stop_time},
          %{socket: socket(), force?: false, changed?: true}
        )

      assert %Event{type: :live_view, name: :render, status: :ok} = event
      assert event.module == TestApp.CounterLive
      assert event.source == [:phoenix, :live_view, :render, :stop]
      assert event.duration == duration
      assert Event.duration(event, :microsecond) == 1500
      assert event.monotonic_time == stop_time - duration
      assert event.system_time == event.monotonic_time + System.time_offset()
      assert event.parent_id == nil and event.trace_id == nil

      assert event.metadata == %{
               view: TestApp.CounterLive,
               component: nil,
               cid: nil,
               socket_id: "phx-test",
               changed?: true,
               force?: false
             }
    end

    test "extracts only safe fields from mount metadata full of secrets" do
      metadata = %{
        socket: socket(),
        session: %{"password" => "session-secret", "user_token" => "token-secret"},
        params: %{"password" => "param-secret"},
        uri: "http://localhost/reset/url-secret-token?api_key=query-secret"
      }

      event = stop([:phoenix, :live_view, :mount], metadata)

      assert event.metadata == %{
               view: TestApp.CounterLive,
               component: nil,
               cid: nil,
               socket_id: "phx-test",
               connected?: true,
               route: "/reset/:token"
             }

      stored = inspect(event, limit: :infinity, printable_limit: :infinity)

      for secret <-
            ~w(session-secret token-secret param-secret url-secret-token query-secret assign-secret private-secret) do
        refute stored =~ secret
      end
    end

    test "keeps handle_event names as strings without creating atoms" do
      name = "never_seen_event_#{System.unique_integer([:positive])}"

      event =
        stop([:phoenix, :live_view, :handle_event], %{
          socket: socket(),
          event: name,
          params: %{"password" => "secret"}
        })

      assert event.name == :handle_event
      assert event.metadata.event == name
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "records component events with the component module and cid" do
      component_socket = socket(assigns: %{__changed__: %{}, myself: %{cid: 7}, secret: "s"})

      handle =
        stop([:phoenix, :live_component, :handle_event], %{
          socket: component_socket,
          component: TestApp.CounterComponent,
          event: "inc",
          params: %{"secret" => "s"}
        })

      assert %Event{type: :live_component, name: :handle_event, module: TestApp.CounterComponent} =
               handle

      assert handle.metadata.cid == 7
      assert handle.metadata.event == "inc"
      assert handle.metadata.view == TestApp.CounterLive

      update =
        stop([:phoenix, :live_component, :update], %{
          socket: socket(),
          component: TestApp.CounterComponent,
          assigns_sockets: [{%{secret: "s"}, component_socket}]
        })

      assert update.metadata.cid == 7
      assert update.metadata.count == 1

      batch =
        stop([:phoenix, :live_component, :update], %{
          socket: socket(),
          component: TestApp.CounterComponent,
          assigns_sockets: List.duplicate({%{}, component_socket}, 3)
        })

      assert batch.metadata.cid == nil
      assert batch.metadata.count == 3
    end

    test "records LiveView 1.2 component re-renders as :live_component renders" do
      event =
        stop([:phoenix, :live_view, :render], %{
          socket: socket(),
          component: TestApp.CounterComponent,
          id: "user-provided-id",
          cid: 3,
          force?: false,
          changed?: true
        })

      assert %Event{type: :live_component, name: :render, module: TestApp.CounterComponent} =
               event

      assert event.source == [:phoenix, :live_view, :render, :stop]
      assert event.metadata.cid == 3
      assert event.metadata.view == TestApp.CounterLive
      refute Map.has_key?(event.metadata, :id)
    end

    test "marks exceptions and keeps only the kind and exception module" do
      event =
        Instrumentation.handle_event(
          [:phoenix, :live_view, :handle_event, :exception],
          %{duration: 10, monotonic_time: System.monotonic_time()},
          %{
            socket: socket(),
            event: "save",
            params: %{},
            kind: :error,
            reason: %RuntimeError{message: "secret in message"},
            stacktrace: [{TestApp.CounterLive, :handle_event, [%{"password" => "x"}], []}]
          }
        )

      assert event.status == :exception
      assert event.metadata.kind == :error
      assert event.metadata.exception == RuntimeError
      refute inspect(event) =~ "secret in message"
      refute Map.has_key?(event.metadata, :stacktrace)

      thrown =
        Instrumentation.handle_event(
          [:phoenix, :live_view, :mount, :exception],
          %{duration: 10, monotonic_time: System.monotonic_time()},
          %{socket: socket(), kind: :throw, reason: {:secret, "x"}, stacktrace: []}
        )

      assert thrown.metadata.kind == :throw
      assert thrown.metadata.exception == nil
    end

    test "tolerates missing or unexpected metadata without raising" do
      for span <- @spans, outcome <- [:stop, :exception] do
        for metadata <- [%{}, %{socket: :not_a_socket, uri: 123, event: :atom, component: "x"}] do
          event = Instrumentation.handle_event(span ++ [outcome], %{}, metadata)

          assert %Event{metadata: %{view: nil, cid: nil}} = event
          assert event.duration == 0
        end
      end
    end

    test "ignores events it does not know" do
      assert Instrumentation.handle_event([:phoenix, :live_view, :mount, :start], %{}, %{}) ==
               :ignore

      assert Instrumentation.handle_event([:other, :event], %{}, %{}) == :ignore

      assert Instrumentation.handle_event(
               [:phoenix, :endpoint, :render, :stop],
               %{duration: 1},
               %{}
             ) ==
               :ignore
    end
  end

  describe "handle_event/3 for destroyed" do
    test "records a point-in-time :live_component event" do
      event =
        Instrumentation.handle_event(@destroyed, %{}, %{
          socket: socket(assigns: %{secret: "s"}),
          component: TestApp.CounterComponent,
          cid: 4,
          live_view_socket: socket()
        })

      assert %Event{type: :live_component, name: :destroyed, status: :ok, duration: nil} = event
      assert event.module == TestApp.CounterComponent

      assert event.metadata == %{
               view: TestApp.CounterLive,
               component: TestApp.CounterComponent,
               cid: 4,
               socket_id: "phx-test"
             }
    end
  end
end
