defmodule LiveViewVisualizerWeb.DisabledError do
  @moduledoc """
  Raised when the dashboard is requested while the visualizer is disabled.

  Rendered by Phoenix as a 404, so a disabled visualizer looks like a route
  that does not exist.
  """
  defexception message: "LiveViewVisualizer is disabled", plug_status: 404
end

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule LiveViewVisualizerWeb.Router do
    @moduledoc """
    Mounts the LiveView DevTools dashboard in a Phoenix router.

        # lib/my_app_web/router.ex
        if Application.compile_env(:my_app, :dev_routes) do
          import LiveViewVisualizerWeb.Router

          scope "/dev" do
            pipe_through :browser
            live_visualizer "/liveview"
          end
        end

    Phoenix applications generated with `mix phx.new` already set
    `config :my_app, dev_routes: true` in `config/dev.exs` only, and use the same
    block for `live_dashboard`. That keeps the route out of production builds
    entirely. Independently of the route, the dashboard refuses to mount
    (404) unless `config :liveview_visualizer, enabled: true` is set.

    The dashboard is rendered with its own root layout, styles and LiveView
    client. It works whatever the application's layouts, CSS or JavaScript look
    like. It only needs the application's LiveView socket.

    ## Options

      * `:live_socket_path` - the path of the application's LiveView socket, as
        declared with `socket "/live", Phoenix.LiveView.Socket` in the endpoint.
        Defaults to `"/live"`.
      * `:live_session_name` - the name of the `live_session` created for the
        dashboard. Defaults to `:liveview_visualizer`. A `live_session` cannot
        be nested, so do not call `live_visualizer` inside one.
      * `:as` - the route helper name. Defaults to `:liveview_visualizer`.

    """

    @doc "Defines the dashboard route at `path`. See the module documentation."
    defmacro live_visualizer(path, opts \\ []) do
      quote bind_quoted: binding() do
        scope path, alias: false, as: false do
          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

          live_session Keyword.get(opts, :live_session_name, :liveview_visualizer),
            root_layout: {LiveViewVisualizerWeb.Layouts, :root} do
            live("/", LiveViewVisualizerWeb.DashboardLive, :index,
              as: Keyword.get(opts, :as, :liveview_visualizer),
              private: %{live_socket_path: Keyword.get(opts, :live_socket_path, "/live")}
            )
          end
        end
      end
    end
  end

  defmodule LiveViewVisualizerWeb.Layouts do
    @moduledoc false
    # A self-contained root layout: the Phoenix and LiveView clients are inlined
    # from the installed dependencies, so their versions always match the
    # server and nothing is loaded from the network.
    use Phoenix.Component

    def root(assigns) do
      assigns =
        assign(assigns,
          scripts: client_scripts(),
          socket_path: socket_path(assigns[:conn])
        )

      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
          <meta name="robots" content="noindex" />
          <title>LiveView DevTools</title>
        </head>
        <body class="lvv-body">
          {@inner_content}
          <script><%= Phoenix.HTML.raw(@scripts) %></script>
          <script data-socket-path={@socket_path}>
            (function () {
              var csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
              var path = document.currentScript.getAttribute("data-socket-path");
              var liveSocket = new LiveView.LiveSocket(path, Phoenix.Socket, {params: {_csrf_token: csrf}});
              liveSocket.connect();
              window.liveViewVisualizerSocket = liveSocket;
            })();
          </script>
        </body>
      </html>
      """
    end

    defp client_scripts do
      [
        {:phoenix, "priv/static/phoenix.min.js"},
        {:phoenix_live_view, "priv/static/phoenix_live_view.min.js"}
      ]
      |> Enum.map_join(";\n", fn {app, path} ->
        app |> Application.app_dir(path) |> File.read!()
      end)
      |> String.replace("</script", "<\\/script")
    end

    defp socket_path(%Plug.Conn{script_name: script_name, private: private}) do
      prefix = Enum.map_join(script_name, &("/" <> &1))
      prefix <> Map.get(private, :live_socket_path, "/live")
    end

    defp socket_path(_conn), do: "/live"
  end
end
