defmodule LiveViewVisualizer.Instrumentation.LiveView do
  @moduledoc """
  Observes Phoenix LiveView lifecycle telemetry.

  Attached automatically by `LiveViewVisualizer.Telemetry` when the visualizer is
  enabled and `:phoenix_live_view` is available. LiveView modules need no changes.

  ## Observed events

  These spans are emitted by every supported LiveView version (1.0, 1.1, 1.2):

  | Telemetry span | Event `type` / `name` |
  | --- | --- |
  | `[:phoenix, :live_view, :mount]` | `:live_view` / `:mount` |
  | `[:phoenix, :live_view, :handle_params]` | `:live_view` / `:handle_params` |
  | `[:phoenix, :live_view, :handle_event]` | `:live_view` / `:handle_event` |
  | `[:phoenix, :live_view, :render]` | `:live_view` / `:render` |
  | `[:phoenix, :live_component, :handle_event]` | `:live_component` / `:handle_event` |
  | `[:phoenix, :live_component, :update]` | `:live_component` / `:update` |

  From LiveView 1.1.0, the single (non-span) event
  `[:phoenix, :live_component, :destroyed]` is observed as
  `:live_component` / `:destroyed`.

  From LiveView 1.2.0, re-rendering a single LiveComponent also emits a
  `[:phoenix, :live_view, :render]` span with a `:component` key in its metadata.
  It is recorded as `:live_component` / `:render` with the component as `module`.
  The original event name is kept in `source`.

  LiveView emits no telemetry for `handle_info/2`, `handle_async/3` or assign
  changes, so those are not observed. The disconnected (HTTP) render is not
  instrumented by LiveView either. A dead render produces `mount` and
  `handle_params` events, but no `render` event.

  ## Spans

  One event is recorded per *completed* operation, on the span's `:stop` or
  `:exception` event:

    * `duration` comes from `:telemetry.span/3`. The start time is derived
      exactly as `stop monotonic_time - duration`.
    * `:exception` events are recorded with `status: :exception`.

  The `:start` event is also attached, but records nothing. It calls
  `LiveViewVisualizer.Context.enter/1` with the span's `telemetry_span_context`,
  so the event id is allocated when the callback starts. Anything that happens
  inside the callback in the same process, such as an Ecto query or a nested
  LiveComponent update during a render, can then reference it as its parent.
  `:stop`/`:exception` look up the same span context to reuse that id.

  ## Parent and trace ids

    * `parent_id` is the enclosing span *in the same process*. A LiveComponent
      `update` during a `render` has that render as its parent. Top-level
      callbacks have no parent.
    * `trace_id` is the id of the outermost such span (its own id at the top level).
    * `handle_event` and the `render` that follows it are *not* linked. LiveView
      runs them one after another, not nested, so there is no parent
      relationship to record. Grouping them is a presentation concern.

  ## Metadata

  Raw LiveView telemetry metadata contains the whole socket (including assigns),
  the session and the params. None of it is copied. Only these structural
  fields are extracted, before the generic `LiveViewVisualizer.Sanitizer` runs:

    * `:view` - the LiveView module
    * `:component` - the LiveComponent module, or `nil`
    * `:cid` - the LiveComponent id (an integer), or `nil`
    * `:socket_id` - the LiveView's DOM id, which stays the same across the
      disconnected and connected mounts
    * `:connected?` - whether the socket is connected (`mount` and `handle_params` only)
    * `:route` - the router pattern such as `"/users/:id"` (`mount` and
      `handle_params` only), never the concrete path. Concrete paths can contain
      secrets such as password reset tokens.
    * `:event` - the event name (`handle_event` only). It stays a string and is
      never converted to an atom.
    * `:changed?` / `:force?` - render flags (`render` only)
    * `:count` - number of components updated together (`update` only)
    * `:kind` / `:exception` - for failed operations, the failure kind and the
      exception module. Messages, reasons and stacktraces are never stored,
      because they can contain application data.

  Missing values are `nil`. Extraction never raises for unexpected metadata.

  ## The visualizer's own dashboard

  Events from `LiveViewVisualizerWeb.DashboardLive` are ignored, otherwise
  each dashboard render would record events that trigger another refresh.
  """

  @behaviour LiveViewVisualizer.Instrumentation

  alias LiveViewVisualizer.{Context, Event}

  # Phoenix is only guaranteed to be present when LiveView is.
  @compile {:no_warn_undefined, Phoenix.Router}

  @spans [
    [:phoenix, :live_view, :mount],
    [:phoenix, :live_view, :handle_params],
    [:phoenix, :live_view, :handle_event],
    [:phoenix, :live_view, :render],
    [:phoenix, :live_component, :handle_event],
    [:phoenix, :live_component, :update]
  ]

  @destroyed [:phoenix, :live_component, :destroyed]

  # The visualizer's own LiveViews. Recording them would make every dashboard
  # render produce events that trigger another dashboard refresh, forever.
  @own_views [LiveViewVisualizerWeb.DashboardLive]

  @impl true
  def events, do: events_for(live_view_version())

  @doc """
  Returns the telemetry events to attach to for a LiveView `version`.

  Returns `[]` when `version` is `nil`, meaning LiveView is not available, or
  is not a valid version.
  """
  @spec events_for(String.t() | nil) :: [:telemetry.event_name()]
  def events_for(nil), do: []

  def events_for(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        span_events =
          for span <- @spans, suffix <- [:start, :stop, :exception], do: span ++ [suffix]

        if Version.compare(parsed, "1.1.0") == :lt,
          do: span_events,
          else: span_events ++ [@destroyed]

      :error ->
        []
    end
  end

  @doc """
  Returns the version of the available `:phoenix_live_view` application, or `nil`.

  The application is loaded (not started) if needed, which is a no-op when
  it is already loaded and fails harmlessly when it is not installed.
  """
  @spec live_view_version() :: String.t() | nil
  def live_view_version do
    with nil <- Application.spec(:phoenix_live_view, :vsn),
         _ <- Application.load(:phoenix_live_view),
         nil <- Application.spec(:phoenix_live_view, :vsn) do
      nil
    else
      vsn -> List.to_string(vsn)
    end
  end

  @impl true
  def handle_event(_event, _measurements, %{socket: %{view: view}}) when view in @own_views,
    do: :ignore

  def handle_event([:phoenix, :live_component, :destroyed] = source, _measurements, metadata) do
    socket = Map.get(metadata, :live_view_socket)
    component = atom_or_nil(Map.get(metadata, :component))

    Event.new!(
      type: :live_component,
      name: :destroyed,
      module: component,
      source: source,
      metadata: %{
        view: view(socket),
        component: component,
        cid: integer_or_nil(Map.get(metadata, :cid)),
        socket_id: socket_id(socket)
      }
    )
  end

  def handle_event([:phoenix, scope, _name, :start], _measurements, metadata)
      when scope in [:live_view, :live_component] do
    case Map.get(metadata, :telemetry_span_context) do
      nil -> :ok
      span_context -> Context.enter(span_context)
    end

    :ignore
  end

  def handle_event([:phoenix, scope, name, outcome] = source, measurements, metadata)
      when scope in [:live_view, :live_component] and outcome in [:stop, :exception] do
    # Release the context first, so nothing below can leave it behind.
    ids =
      case Map.get(metadata, :telemetry_span_context) do
        nil -> nil
        span_context -> Context.exit(span_context)
      end

    duration = Map.get(measurements, :duration, 0)

    stop_time =
      case measurements do
        %{monotonic_time: time} -> time
        _ -> System.monotonic_time()
      end

    start_time = stop_time - duration
    {type, module, fields} = describe(scope, name, metadata)

    Event.new!(
      Map.to_list(ids || %{}) ++
        [
          type: type,
          name: name,
          status: if(outcome == :stop, do: :ok, else: :exception),
          module: module,
          source: source,
          monotonic_time: start_time,
          system_time: start_time + System.time_offset(),
          duration: duration,
          metadata: if(outcome == :exception, do: put_failure(fields, metadata), else: fields)
        ]
    )
  end

  def handle_event(_event, _measurements, _metadata), do: :ignore

  # LiveView 1.2+ emits single LiveComponent re-renders as live_view render spans.
  defp describe(:live_view, :render, %{component: component} = metadata)
       when is_atom(component) and not is_nil(component) do
    socket = Map.get(metadata, :socket)

    fields =
      socket
      |> base_fields(component, integer_or_nil(Map.get(metadata, :cid)))
      |> Map.merge(render_flags(metadata))

    {:live_component, component, fields}
  end

  defp describe(:live_view, name, metadata) do
    socket = Map.get(metadata, :socket)
    view = view(socket)

    {:live_view, view,
     Map.merge(base_fields(socket, nil, nil), extra_fields(name, socket, metadata))}
  end

  defp describe(:live_component, name, metadata) do
    socket = Map.get(metadata, :socket)
    component = atom_or_nil(Map.get(metadata, :component))

    {cid, extra} =
      case name do
        :update -> update_fields(Map.get(metadata, :assigns_sockets))
        :handle_event -> {cid(socket), %{event: string_or_nil(Map.get(metadata, :event))}}
        _ -> {nil, %{}}
      end

    {:live_component, component, Map.merge(base_fields(socket, component, cid), extra)}
  end

  defp base_fields(socket, component, cid) do
    %{view: view(socket), component: component, cid: cid, socket_id: socket_id(socket)}
  end

  defp extra_fields(name, socket, metadata) when name in [:mount, :handle_params] do
    %{connected?: connected?(socket), route: route(socket, Map.get(metadata, :uri))}
  end

  defp extra_fields(:handle_event, _socket, metadata),
    do: %{event: string_or_nil(Map.get(metadata, :event))}

  defp extra_fields(:render, _socket, metadata), do: render_flags(metadata)
  defp extra_fields(_name, _socket, _metadata), do: %{}

  defp render_flags(metadata) do
    %{
      changed?: boolean_or_nil(Map.get(metadata, :changed?)),
      force?: boolean_or_nil(Map.get(metadata, :force?))
    }
  end

  # `assigns_sockets` is a list of {assigns, component_socket}, one per
  # component instance updated in this batch. Only its length and, for a single
  # instance, its cid are read. The assigns are never touched.
  defp update_fields([{_assigns, socket}]), do: {cid(socket), %{count: 1}}
  defp update_fields(list) when is_list(list), do: {nil, %{count: length(list)}}
  defp update_fields(_other), do: {nil, %{count: nil}}

  defp put_failure(fields, metadata) do
    kind = Map.get(metadata, :kind)

    exception =
      case Map.get(metadata, :reason) do
        %{__exception__: true, __struct__: module} -> module
        _ -> nil
      end

    Map.merge(fields, %{kind: if(kind in [:error, :exit, :throw], do: kind), exception: exception})
  end

  defp view(%{view: view}) when is_atom(view), do: view
  defp view(_socket), do: nil

  defp socket_id(%{id: id}) when is_binary(id), do: id
  defp socket_id(_socket), do: nil

  defp connected?(%{transport_pid: pid}), do: is_pid(pid)
  defp connected?(_socket), do: nil

  defp cid(%{assigns: %{myself: %{cid: cid}}}) when is_integer(cid), do: cid
  defp cid(_socket), do: nil

  # Resolves the router pattern ("/users/:id") through the public
  # Phoenix.Router.route_info/4 API. Any failure just yields nil so that a
  # problem here never costs the whole event.
  defp route(%{router: router}, uri) when is_atom(router) and not is_nil(router) do
    with %URI{path: path, host: host} <- parse_uri(uri),
         %{route: route} when is_binary(route) <-
           Phoenix.Router.route_info(router, "GET", path || "/", host) do
      route
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp route(_socket, _uri), do: nil

  defp parse_uri(uri) when is_binary(uri), do: URI.parse(uri)
  defp parse_uri(%URI{} = uri), do: uri
  defp parse_uri(_uri), do: nil

  defp atom_or_nil(value) when is_atom(value), do: value
  defp atom_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil
end
