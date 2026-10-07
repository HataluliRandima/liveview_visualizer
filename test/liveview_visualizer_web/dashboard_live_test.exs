defmodule LiveViewVisualizerWeb.DashboardLiveTest do
  # Drives the real dashboard, mounted with live_visualizer/2 in the test
  # router, next to real LiveViews. Uses the shared store.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewVisualizer.{Collector, Event, Notifier, Store, TestDB, TestRepo}
  alias LiveViewVisualizer.TestApp.{CounterLive, Product}

  @endpoint LiveViewVisualizer.TestApp.Endpoint
  @app :liveview_visualizer
  @path "/dev/liveview"

  setup do
    LiveViewVisualizer.clear_events()
    {:ok, conn: build_conn()}
  end

  defp dashboard(conn) do
    {:ok, view, _html} = live(conn, @path)
    view
  end

  # The dashboard refreshes shortly after a notification; wait for it.
  defp eventually(fun, attempts \\ 40) do
    if fun.() do
      true
    else
      if attempts == 0, do: flunk("condition not met in time")
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp record(attrs), do: attrs |> Event.new!() |> tap(&(:ok = Collector.collect(&1)))

  defp handle_event_with_queries do
    parent =
      record(
        type: :live_view,
        name: :handle_event,
        module: MyAppWeb.InventoryLive,
        duration: 51_000_000,
        metadata: %{view: MyAppWeb.InventoryLive, socket_id: "phx-inv", event: "search"}
      )

    children =
      for {source, duration} <- [{"products", 13_000_000}, {"stock_levels", 4_000_000}] do
        record(
          type: :ecto,
          name: :query,
          module: Demo.Repo,
          parent_id: parent.id,
          trace_id: parent.id,
          duration: duration,
          metadata: %{repo: Demo.Repo, source: source, command: :select, num_rows: 2}
        )
      end

    render =
      record(
        type: :live_view,
        name: :render,
        module: MyAppWeb.InventoryLive,
        duration: 1_800_000,
        metadata: %{view: MyAppWeb.InventoryLive, socket_id: "phx-inv"}
      )

    {parent, children, render}
  end

  describe "startup" do
    test "renders the dashboard when the visualizer is enabled", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "LIVEVIEW DEVTOOLS"
      assert has_element?(view, "#lvv-status", "● Recording")
      assert has_element?(view, "#lvv-clear", "Clear")
      assert has_element?(view, "#lvv-pause", "Pause")
    end

    test "the root layout is self-contained and connects to the configured socket", %{conn: conn} do
      html = conn |> get(@path) |> html_response(200)

      assert html =~ ~s{<meta name="csrf-token"}
      assert html =~ ~s{data-socket-path="/live"}
      assert html =~ "var LiveView="
      assert html =~ "var Phoenix="
      refute html =~ ~r{<script[^>]+src=}
    end

    test "shows a helpful empty state", %{conn: conn} do
      view = dashboard(conn)

      assert has_element?(view, "#lvv-empty", "No LiveView activity yet.")
      assert has_element?(view, "#lvv-empty", "events will appear here automatically")
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

    test "the dashboard does not start and responds 404", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, @path) end)
      assert_raise LiveViewVisualizerWeb.DisabledError, fn -> live(build_conn(), @path) end
    end
  end

  describe "rendering events" do
    test "shows stats, the LiveView list and correlated trees", %{conn: conn} do
      {parent, [q1, q2], render} = handle_event_with_queries()
      view = dashboard(conn)

      assert has_element?(view, "#lvv-stat-live-views", "1")
      assert has_element?(view, "#lvv-stat-events", "4")
      assert has_element?(view, "#lvv-stat-queries", "2")
      assert has_element?(view, "#lvv-stat-errors", "0")
      assert has_element?(view, "#lvv-live-views", "InventoryLive")
      assert has_element?(view, "#lvv-live-views", "4 events · 2 queries")

      # parent ├── child └── child, nested by parent_id
      assert has_element?(
               view,
               "#lvv-node-#{parent.id}[data-role=root]",
               ~s{handle_event("search")}
             )

      assert has_element?(
               view,
               "#lvv-node-#{parent.id} > ul > #lvv-node-#{q1.id}",
               "Ecto query · products"
             )

      assert has_element?(
               view,
               "#lvv-node-#{parent.id} > ul > #lvv-node-#{q2.id}",
               "Ecto query · stock_levels"
             )

      assert has_element?(view, "#lvv-node-#{parent.id}", "51.0ms")

      # render has no parent_id: it is a root of its own, not a child of handle_event.
      assert has_element?(view, "#lvv-node-#{render.id}[data-role=root]", "render")
      refute has_element?(view, "#lvv-node-#{parent.id} #lvv-node-#{render.id}")

      assert has_element?(view, "#lvv-group-phx-inv", "InventoryLive")
    end

    test "events without a LiveView are shown as roots outside LiveView callbacks", %{conn: conn} do
      background =
        record(
          type: :ecto,
          name: :query,
          module: Demo.Repo,
          metadata: %{repo: Demo.Repo, source: "jobs"}
        )

      view = dashboard(conn)

      assert has_element?(view, "#lvv-group-other", "Outside LiveView callbacks")

      assert has_element?(
               view,
               "#lvv-group-other #lvv-node-#{background.id}[data-role=root]",
               "jobs"
             )
    end

    test "failures are visually marked", %{conn: conn} do
      failed =
        record(
          type: :live_view,
          name: :handle_event,
          module: MyAppWeb.InventoryLive,
          status: :exception,
          metadata: %{view: MyAppWeb.InventoryLive, socket_id: "phx-inv", event: "save"}
        )

      query =
        record(
          type: :ecto,
          name: :query,
          parent_id: failed.id,
          status: :error,
          metadata: %{repo: Demo.Repo, exception: Postgrex.Error, error_code: :undefined_table}
        )

      view = dashboard(conn)

      assert has_element?(view, "#lvv-node-#{failed.id}.lvv-failed", "EXCEPTION")
      assert has_element?(view, "#lvv-node-#{query.id}.lvv-failed", "ERROR")
      assert has_element?(view, "#lvv-stat-errors", "2")

      view |> element("#lvv-node-#{failed.id} > .lvv-row") |> render_click()
      assert has_element?(view, "#lvv-details", "EXCEPTION")
    end
  end

  describe "event details" do
    test "selecting an event shows its stored fields", %{conn: conn} do
      {parent, [q1, _q2], _render} = handle_event_with_queries()
      view = dashboard(conn)

      view |> element("#lvv-node-#{parent.id} > .lvv-row") |> render_click()
      details = view |> element("#lvv-details") |> render()
      assert details =~ "handle_event"
      assert details =~ "search"
      assert details =~ "MyAppWeb.InventoryLive"
      assert details =~ ~r{<dt>Children</dt><dd[^>]*>2</dd>}
      assert details =~ ~r{<dt>Parent</dt><dd[^>]*>none</dd>}

      view |> element("#lvv-node-#{q1.id} > .lvv-row") |> render_click()
      details = view |> element("#lvv-details") |> render()
      assert details =~ ~r{<dt>Repo</dt><dd[^>]*>Demo\.Repo</dd>}
      assert details =~ ~r{<dt>Source</dt><dd[^>]*>products</dd>}
      assert details =~ ~r{<dt>Command</dt><dd[^>]*>select</dd>}
      assert details =~ ~r{<dt>Rows</dt><dd[^>]*>2</dd>}
      assert details =~ ~s{handle_event(&quot;search&quot;) · InventoryLive}

      view |> element("#lvv-details button[phx-click=close_details]") |> render_click()
      assert has_element?(view, "#lvv-details", "Select an event")
    end
  end

  describe "filters and search" do
    setup do
      {parent, children, render} = handle_event_with_queries()

      failed =
        record(
          type: :live_view,
          name: :mount,
          module: CounterLive,
          status: :exception,
          metadata: %{view: CounterLive, socket_id: "phx-counter"}
        )

      %{parent: parent, children: children, render: render, failed: failed}
    end

    defp filter(view, params), do: view |> element("#lvv-filters") |> render_change(params)

    test "by type keeps matching trees and dims their context", %{conn: conn} = ctx do
      view = dashboard(conn)
      filter(view, %{"type" => "ecto"})

      assert has_element?(view, "#lvv-node-#{ctx.parent.id}.lvv-dim")
      refute has_element?(view, "#lvv-node-#{hd(ctx.children).id}.lvv-dim")
      refute has_element?(view, "#lvv-node-#{ctx.render.id}")
      refute has_element?(view, "#lvv-node-#{ctx.failed.id}")
    end

    test "by LiveView", %{conn: conn} = ctx do
      view = dashboard(conn)
      filter(view, %{"view" => inspect(CounterLive)})

      assert has_element?(view, "#lvv-node-#{ctx.failed.id}")
      refute has_element?(view, "#lvv-node-#{ctx.parent.id}")

      # The sidebar list toggles the same filter.
      view |> element("#lvv-live-views button", "CounterLive") |> render_click()
      assert has_element?(view, "#lvv-node-#{ctx.parent.id}")
    end

    test "by status", %{conn: conn} = ctx do
      view = dashboard(conn)
      filter(view, %{"status" => "exception"})

      assert has_element?(view, "#lvv-node-#{ctx.failed.id}")
      refute has_element?(view, "#lvv-node-#{ctx.parent.id}")
    end

    test "unknown filter values are ignored", %{conn: conn} = ctx do
      view = dashboard(conn)
      filter(view, %{"view" => "Elixir.Not.A.Module", "type" => "nope", "status" => "nope"})

      assert has_element?(view, "#lvv-node-#{ctx.parent.id}")
      assert has_element?(view, "#lvv-node-#{ctx.failed.id}")
    end

    test "search by module, event name, source and repo", %{conn: conn} = ctx do
      view = dashboard(conn)
      [q1, q2] = ctx.children

      filter(view, %{"query" => "CounterLive"})
      assert has_element?(view, "#lvv-node-#{ctx.failed.id}")
      refute has_element?(view, "#lvv-node-#{ctx.parent.id}")

      filter(view, %{"query" => "search"})
      refute has_element?(view, "#lvv-node-#{ctx.parent.id}.lvv-dim")
      refute has_element?(view, "#lvv-node-#{ctx.failed.id}")

      filter(view, %{"query" => "stock_levels"})
      refute has_element?(view, "#lvv-node-#{q2.id}.lvv-dim")
      assert has_element?(view, "#lvv-node-#{q1.id}.lvv-dim")

      filter(view, %{"query" => "Demo.Repo"})
      refute has_element?(view, "#lvv-node-#{q1.id}.lvv-dim")

      filter(view, %{"query" => "nothing-matches"})
      assert has_element?(view, "#lvv-traces", "No events match the current filters.")
    end
  end

  describe "clear" do
    @describetag :postgres

    test "empties the visualizer's store only", %{conn: conn} do
      TestDB.reset()
      TestRepo.insert!(%Product{name: "Kept", price: 1})
      {:ok, counter, _html} = live(build_conn(), "/counter")
      render_click(counter, "inc")

      view = dashboard(conn)
      assert Store.count() > 0
      refute has_element?(view, "#lvv-empty")

      view |> element("#lvv-clear") |> render_click()

      assert Store.count() == 0
      assert has_element?(view, "#lvv-empty", "No LiveView activity yet.")

      # The application, its database and its LiveViews are untouched.
      assert [%Product{name: "Kept"}] = TestRepo.all(Product)
      assert Process.alive?(counter.pid)
      assert render_click(counter, "inc") =~ "Count: 2"

      # ...and the dashboard fills up again.
      eventually(fn -> has_element?(view, "#lvv-traces", ~s{handle_event("inc")}) end)
    end
  end

  describe "live updates" do
    test "real LiveView activity appears without reloading", %{conn: conn} do
      view = dashboard(conn)
      assert has_element?(view, "#lvv-empty")

      {:ok, counter, _html} = live(build_conn(), "/counter")
      render_click(counter, "inc")

      eventually(fn -> has_element?(view, "#lvv-traces", ~s{handle_event("inc")}) end)
      assert has_element?(view, "#lvv-live-views", "CounterLive")
    end

    test "a notification makes the dashboard read the new event from the store", %{conn: conn} do
      view = dashboard(conn)

      # Bypass the collector: store an event and send only its id.
      event =
        Event.new!(
          type: :live_view,
          name: :render,
          metadata: %{socket_id: "phx-x", view: CounterLive}
        )

      :ok = Store.record(event)
      refute has_element?(view, "#lvv-node-#{event.id}")

      Notifier.event_recorded(event.id)
      eventually(fn -> has_element?(view, "#lvv-node-#{event.id}") end)
    end

    test "a burst is applied in bulk, and the window stays within the store's capacity", %{
      conn: conn
    } do
      view = dashboard(conn)
      for i <- 1..150, do: record(type: :ecto, name: :query, metadata: %{source: "t#{i}"})

      # The test store keeps 100 events (config/test.exs).
      eventually(fn -> has_element?(view, "#lvv-node-#{List.last(Store.recent()).id}") end)
      assert has_element?(view, "#lvv-stat-events", "100")
      assert has_element?(view, "#lvv-traces", "Ecto query · t150")
      refute has_element?(view, "#lvv-traces", "Ecto query · t50<")
    end

    test "pause stops updating the dashboard while recording continues", %{conn: conn} do
      view = dashboard(conn)
      view |> element("#lvv-pause") |> render_click()
      assert has_element?(view, "#lvv-status", "○ Paused")

      event = record(type: :ecto, name: :query, metadata: %{source: "while_paused"})

      eventually(fn -> has_element?(view, "#lvv-status", "1 new") end)
      refute has_element?(view, "#lvv-node-#{event.id}")
      assert [%Event{}] = Store.recent()

      view |> element("#lvv-pause") |> render_click()
      assert has_element?(view, "#lvv-status", "● Recording")
      assert has_element?(view, "#lvv-node-#{event.id}")
    end

    test "clearing from elsewhere empties every open dashboard", %{conn: conn} do
      record(type: :ecto, name: :query, metadata: %{source: "x"})
      view = dashboard(conn)
      refute has_element?(view, "#lvv-empty")

      LiveViewVisualizer.clear_events()
      eventually(fn -> has_element?(view, "#lvv-empty") end)
    end
  end

  describe "sensitive data" do
    test "only safely stored, allowlisted fields can be rendered", %{conn: conn} do
      # Through the collector: sanitized before storage.
      sanitized =
        record(
          type: :live_view,
          name: :handle_event,
          metadata: %{
            view: CounterLive,
            socket_id: "phx-s",
            event: "save",
            password: "collector-secret"
          }
        )

      # Directly into the store, bypassing sanitization, with keys the
      # dashboard does not know about.
      raw =
        Event.new!(
          type: :ecto,
          name: :query,
          metadata: %{
            source: "users",
            query: "SELECT secret_sql",
            params: ["raw-param-secret"],
            note: "raw-note"
          }
        )

      :ok = Store.record(raw)

      view = dashboard(conn)

      for event <- [sanitized, raw] do
        view |> element("#lvv-node-#{event.id} > .lvv-row") |> render_click()
        html = render(view)

        for secret <- ~w(collector-secret secret_sql raw-param-secret raw-note) do
          refute html =~ secret
        end
      end
    end

    @tag :postgres
    test "real LiveView and Ecto activity with secrets renders none of them", %{conn: conn} do
      TestDB.reset()
      TestRepo.insert!(%Product{name: "Widget", price: 1})

      session_conn = Plug.Test.init_test_session(build_conn(), %{"password" => "session-secret"})
      {:ok, products, _html} = live(session_conn, "/products?token=query-secret")
      render_click(products, "search", %{"q" => "search-secret"})

      view = dashboard(conn)
      ids = Enum.map(Store.recent(), & &1.id)

      html =
        Enum.reduce(ids, "", fn id, acc ->
          view |> element("#lvv-node-#{id} > .lvv-row") |> render_click()
          acc <> render(view)
        end)

      assert html =~ "Ecto query · products"

      for secret <- ~w(session-secret query-secret search-secret SELECT) do
        refute html =~ secret
      end
    end
  end

  describe "self-observation" do
    test "using the dashboard records no events of its own", %{conn: conn} do
      record(type: :ecto, name: :query, metadata: %{source: "x"})
      view = dashboard(conn)

      view |> element("#lvv-filters") |> render_change(%{"query" => "x"})
      view |> element("#lvv-pause") |> render_click()
      view |> element("#lvv-pause") |> render_click()
      Process.sleep(200)

      assert Enum.map(Store.recent(), & &1.metadata[:source]) == ["x"]
    end
  end
end
