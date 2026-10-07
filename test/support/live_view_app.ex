defmodule LiveViewVisualizer.TestApp do
  @moduledoc false
  # A minimal, real Phoenix application used by the integration tests. Nothing
  # here references the visualizer: the LiveViews are written exactly as an
  # application would write them.

  @session_options [store: :cookie, key: "_lvv_test", signing_salt: "lvv-test", same_site: "Lax"]

  def session_options, do: @session_options
end

defmodule LiveViewVisualizer.TestApp.CounterLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    # Keep sensitive session data in assigns to prove assigns are never stored.
    {:ok, assign(socket, count: 0, secret: session["password"])}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  @impl true
  def render(assigns) do
    ~H"""
    <button id="inc" phx-click="inc">Count: {@count}</button>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.ResetPasswordLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(%{"token" => token}, _session, socket), do: {:ok, assign(socket, token: token)}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset", %{"password" => _password}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="reset" phx-submit="reset"><input name="password" type="password" /></form>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.CounterComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign_new(:count, fn -> 0 end)}

  @impl true
  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  @impl true
  def render(assigns) do
    ~H"""
    <button id={@id} phx-click="inc" phx-target={@myself}>Component: {@count}</button>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.ComponentsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias LiveViewVisualizer.TestApp.CounterComponent

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, show: true)}

  @impl true
  def handle_event("hide", _params, socket), do: {:noreply, assign(socket, show: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component :if={@show} module={CounterComponent} id="counter-component" />
      <button id="hide" phx-click="hide">Hide</button>
    </div>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.CrashLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event("boom", _params, _socket), do: raise("boom from handle_event")

  @impl true
  def render(assigns) do
    ~H"""
    <button id="boom" phx-click="boom">Boom</button>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.CrashMountLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, _socket), do: raise(ArgumentError, "boom from mount")

  @impl true
  def render(assigns), do: ~H"<div></div>"
end

defmodule LiveViewVisualizer.TestApp.StockComponent do
  @moduledoc false
  # Queries the database from update/2, i.e. during the parent's render.
  use Phoenix.LiveComponent

  alias LiveViewVisualizer.TestApp.Products

  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign(stock: length(Products.list_stock_levels()))}

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id}>Stock rows: {@stock}</span>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.ProductsLive do
  @moduledoc false
  # An ordinary LiveView that uses an ordinary context. Nothing here refers to
  # the visualizer.
  use Phoenix.LiveView

  alias LiveViewVisualizer.TestApp.{Products, StockComponent}
  alias LiveViewVisualizer.TestRepo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, count: Products.count(), products: [], show_stock: false)}
  end

  @impl true
  def handle_event("load", _params, socket) do
    products = Products.list_products()
    _stock = Products.list_stock_levels()
    {:noreply, assign(socket, products: products)}
  end

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, products: Products.search(q))}

  def handle_event("load_in_task", _params, socket) do
    products = Task.async(fn -> Products.list_products() end) |> Task.await()
    {:noreply, assign(socket, products: products)}
  end

  def handle_event("load_later", _params, socket) do
    send(self(), :load)
    {:noreply, socket}
  end

  def handle_event("show_stock", _params, socket),
    do: {:noreply, assign(socket, show_stock: true)}

  def handle_event("fail", _params, socket) do
    TestRepo.query!("SELECT * FROM lvv_table_that_does_not_exist")
    {:noreply, socket}
  end

  @impl true
  def handle_info(:load, socket),
    do: {:noreply, assign(socket, products: Products.list_products())}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p id="count">Products: {@count}</p>
      <ul>
        <li :for={product <- @products}>{product.name}</li>
      </ul>
      <.live_component :if={@show_stock} module={StockComponent} id="stock" />
    </div>
    """
  end
end

defmodule LiveViewVisualizer.TestApp.ErrorHTML do
  @moduledoc false
  # Phoenix renders this for exceptions raised during a request, like any app.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule LiveViewVisualizer.TestApp.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias LiveViewVisualizer.TestApp

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)

    live("/counter", TestApp.CounterLive)
    live("/reset/:token", TestApp.ResetPasswordLive)
    live("/components", TestApp.ComponentsLive)
    live("/crash", TestApp.CrashLive)
    live("/crash-mount", TestApp.CrashMountLive)
    live("/products", TestApp.ProductsLive)
  end
end

defmodule LiveViewVisualizer.TestApp.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :liveview_visualizer

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: LiveViewVisualizer.TestApp.session_options()]]
  )

  plug(Plug.Session, LiveViewVisualizer.TestApp.session_options())
  plug(LiveViewVisualizer.TestApp.Router)
end
