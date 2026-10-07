defmodule LiveViewVisualizer.Instrumentation.EctoIntegrationTest do
  # Real queries against PostgreSQL through two real repos, from LiveViews,
  # Tasks and plain processes. Uses the shared store and database.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import LiveViewVisualizer.SupervisionHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveViewVisualizer.{AnalyticsRepo, Event, Store, Telemetry, TestDB, TestRepo}
  alias LiveViewVisualizer.Instrumentation.Ecto, as: Instrumentation
  alias LiveViewVisualizer.Instrumentation.LiveView, as: LiveViewInstrumentation
  alias LiveViewVisualizer.TestApp.{PageView, Product, ProductsLive, StockComponent, User}

  @moduletag :postgres

  @endpoint LiveViewVisualizer.TestApp.Endpoint
  @app :liveview_visualizer
  @test_repo_event [:live_view_visualizer, :test_repo, :query]
  @analytics_event [:analytics, :db, :query]

  setup do
    TestDB.reset()
    TestRepo.insert!(%Product{name: "Widget", price: 3})
    Store.clear()
    :ok
  end

  defp queries, do: Enum.filter(Store.recent(), &(&1.type == :ecto))
  defp find(events, name), do: Enum.find(events, &(&1.name == name))

  defp ecto_sql_at_least?(version) do
    Application.spec(:ecto_sql, :vsn) |> List.to_string() |> Version.compare(version) != :lt
  end

  defp visualizer_handler_ids(event) do
    for %{id: {Telemetry, _} = id, event_name: ^event} <- :telemetry.list_handlers(event), do: id
  end

  describe "automatic attachment" do
    test "listens for repo starts and attaches every running repo's query event" do
      assert Instrumentation in Telemetry.attached()
      assert visualizer_handler_ids([:ecto, :repo, :init]) != []
      assert length(visualizer_handler_ids(@test_repo_event)) == 1
      # AnalyticsRepo uses a custom telemetry_prefix, discovered from the repo itself.
      assert length(visualizer_handler_ids(@analytics_event)) == 1
    end

    test "a repo started after the visualizer is attached before its first query" do
      AnalyticsRepo.stop()
      Store.clear()

      {:ok, pid} = AnalyticsRepo.start_link()
      Process.unlink(pid)

      AnalyticsRepo.all(PageView)

      assert [%Event{module: AnalyticsRepo}] = queries()
      # Restarting the repo did not duplicate the handler.
      assert length(visualizer_handler_ids(@analytics_event)) == 1
    end

    test "repos already running are discovered when the visualizer restarts" do
      stop_child(Telemetry)
      assert visualizer_handler_ids(@test_repo_event) == []
      restart_child(Telemetry)

      TestRepo.all(Product)
      AnalyticsRepo.all(PageView)

      assert queries() |> Enum.map(& &1.module) |> Enum.sort() == [AnalyticsRepo, TestRepo]
    end
  end

  describe "queries from LiveViews" do
    test "records handle_event, its queries and the render, with queries parented to the callback" do
      {:ok, view, _html} = live(build_conn(), "/products")
      Store.clear()

      assert render_click(view, "load") =~ "Widget"

      events = Store.recent()

      assert Enum.map(events, &{&1.type, &1.name, &1.metadata[:source]}) == [
               {:ecto, :query, "products"},
               {:ecto, :query, "stock_levels"},
               {:live_view, :handle_event, nil},
               {:live_view, :render, nil}
             ]

      handle_event = find(events, :handle_event)
      render = find(events, :render)
      [products, stock] = Enum.filter(events, &(&1.type == :ecto))

      for query <- [products, stock] do
        assert query.parent_id == handle_event.id
        assert query.trace_id == handle_event.id
        assert query.pid == view.pid
        assert query.module == TestRepo
        assert query.status == :ok
        assert is_integer(query.duration) and query.duration > 0
        assert query.metadata.command == :select

        # The query ran inside the callback's time window.
        assert query.monotonic_time >= handle_event.monotonic_time

        assert query.monotonic_time + query.duration <=
                 handle_event.monotonic_time + handle_event.duration
      end

      assert products.metadata.num_rows == 1
      assert products.monotonic_time < stock.monotonic_time

      # render runs after handle_event returns: no relationship is invented.
      assert render.parent_id == nil
      assert render.trace_id == render.id
    end

    test "mount queries belong to the respective mount" do
      {:ok, view, _html} = live(build_conn(), "/products")

      [dead_mount, connected_mount] =
        Enum.filter(Store.recent(), &(&1.module == ProductsLive and &1.name == :mount))

      [dead_query, connected_query] = queries()

      assert dead_query.parent_id == dead_mount.id
      assert dead_query.pid == self()
      assert connected_query.parent_id == connected_mount.id
      assert connected_query.pid == view.pid
    end

    test "queries in a component's update belong to the update, inside the render's trace" do
      {:ok, view, _html} = live(build_conn(), "/products")
      Store.clear()

      render_click(view, "show_stock")

      events = Store.recent()
      [query] = Enum.filter(events, &(&1.type == :ecto))
      update = Enum.find(events, &(&1.module == StockComponent and &1.name == :update))
      render = Enum.find(events, &(&1.module == ProductsLive and &1.name == :render))

      assert query.parent_id == update.id
      assert update.parent_id == render.id
      assert query.trace_id == render.id
      assert update.trace_id == render.id
    end

    test "queries in a Task get no parent, because the callback may have ended" do
      {:ok, view, _html} = live(build_conn(), "/products")
      Store.clear()

      render_click(view, "load_in_task")

      [query] = queries()
      assert query.parent_id == nil
      assert query.trace_id == nil
      assert query.pid != view.pid
    end

    test "queries in handle_info get no parent, because LiveView emits no span for it" do
      {:ok, view, _html} = live(build_conn(), "/products")
      render_click(view, "load")
      Store.clear()

      render_click(view, "load_later")
      # render/1 waits until the LiveView has processed the :load message.
      render(view)

      [query] = queries()
      assert query.pid == view.pid
      assert query.parent_id == nil
      assert query.trace_id == nil
    end

    test "queries from processes unrelated to any LiveView are captured without a parent" do
      parent = self()

      worker =
        spawn(fn ->
          TestRepo.all(Product)
          send(parent, :done)
        end)

      assert_receive :done

      assert [
               %Event{
                 pid: ^worker,
                 parent_id: nil,
                 trace_id: nil,
                 metadata: %{source: "products"}
               }
             ] =
               queries()
    end
  end

  describe "correlation safety" do
    test "a span whose handlers were detached mid-flight never becomes a parent" do
      :telemetry.span([:phoenix, :live_view, :handle_event], %{event: "simulated"}, fn ->
        TestRepo.query!("SELECT 1")

        # An operator detaches the LiveView instrumentation while the callback runs:
        # its :stop will never be observed.
        :ok = Telemetry.detach(LiveViewInstrumentation)
        TestRepo.query!("SELECT 2")
        {:ok, %{}}
      end)

      on_exit(fn -> Telemetry.attach(LiveViewInstrumentation) end)

      # Later, outside any callback, in the same process.
      TestRepo.query!("SELECT 3")

      [first, second, third] = queries()
      assert is_integer(first.parent_id)
      assert second.parent_id == nil
      assert third.parent_id == nil

      # Re-attaching starts correlating cleanly again.
      :ok = Telemetry.attach(LiveViewInstrumentation)
      Store.clear()

      :telemetry.span([:phoenix, :live_view, :handle_event], %{event: "again"}, fn ->
        TestRepo.query!("SELECT 4")
        {:ok, %{}}
      end)

      [query, span] = Store.recent()
      assert query.parent_id == span.id
    end
  end

  describe "multiple repositories" do
    test "queries are attributed to the repo that ran them" do
      TestRepo.all(Product)
      AnalyticsRepo.insert!(%PageView{path: "/products"})

      [products, page_view] = queries()

      assert products.module == TestRepo
      assert products.metadata.repo == TestRepo
      assert products.source == @test_repo_event

      assert page_view.module == AnalyticsRepo
      assert page_view.metadata.repo == AnalyticsRepo
      # Ecto SQL reports the source of writes only since 3.11.0.
      expected_source = if ecto_sql_at_least?("3.11.0"), do: "page_views", else: nil
      assert page_view.metadata.source == expected_source
      assert page_view.metadata.command == :insert
      assert page_view.source == @analytics_event
    end
  end

  describe "sensitive data" do
    test "parameters, rows, SQL and error details never reach the store" do
      email = "alice-secret@example.com"
      attrs = %{email: email, password_hash: "hash-hunter2", api_token: "token-s3cr3t"}

      TestRepo.insert!(User.changeset(%User{}, attrs))
      TestRepo.get_by!(User, email: email)
      TestRepo.get_by!(User, api_token: "token-s3cr3t")
      TestRepo.query!("SELECT $1::text AS secret", ["raw-param-secret"])

      # The unique violation's error detail contains the email.
      assert {:error, _changeset} = TestRepo.insert(User.changeset(%User{}, attrs))

      {:ok, view, _html} = live(build_conn(), "/products")
      render_click(view, "search", %{"q" => "search-term-secret"})

      events = Store.recent()
      assert length(queries()) >= 6

      stored = inspect(events, limit: :infinity, printable_limit: :infinity)

      for secret <-
            [email, "hash-hunter2", "token-s3cr3t", "raw-param-secret", "search-term-secret"] ++
              ["SELECT", "password_hash", "api_token", "already exists"] do
        refute stored =~ secret, "#{inspect(secret)} leaked into the store"
      end

      allowed = ~w(repo source command num_rows exception error_code)a

      for query <- queries() do
        assert query.metadata |> Map.keys() |> Enum.all?(&(&1 in allowed))

        assert query.measurements
               |> Map.keys()
               |> Enum.all?(&(&1 in ~w(query_time queue_time decode_time idle_time)a))
      end
    end
  end

  describe "failures" do
    test "a failing query raises exactly as without the visualizer and is recorded as :error" do
      observed =
        assert_raise Postgrex.Error, fn -> TestRepo.query!("SELECT * FROM lvv_missing") end

      :ok = Telemetry.detach(Instrumentation)
      on_exit(fn -> Telemetry.attach(Instrumentation) end)

      unobserved =
        assert_raise Postgrex.Error, fn -> TestRepo.query!("SELECT * FROM lvv_missing") end

      assert observed.postgres.code == unobserved.postgres.code
      assert Exception.message(observed) == Exception.message(unobserved)

      assert [
               %Event{
                 status: :error,
                 metadata: %{exception: Postgrex.Error, error_code: :undefined_table}
               }
             ] =
               queries()
    end

    test "constraint errors still come back as changesets" do
      attrs = %{email: "dup@example.com"}
      TestRepo.insert!(User.changeset(%User{}, attrs))
      Store.clear()

      assert {:error, %Ecto.Changeset{errors: [email: {"has already been taken", _}]}} =
               TestRepo.insert(User.changeset(%User{}, attrs))

      assert [%Event{status: :error, metadata: %{error_code: :unique_violation}}] = queries()
    end

    test "a failing query inside handle_event is parented to the callback that raised" do
      {:ok, view, _html} = live(build_conn(), "/products")
      Store.clear()

      Process.flag(:trap_exit, true)
      {_reason, _log} = with_log(fn -> catch_exit(render_click(view, "fail")) end)

      [query] = queries()
      handle_event = Enum.find(Store.recent(), &(&1.name == :handle_event))

      assert handle_event.status == :exception
      assert handle_event.metadata.exception == Postgrex.Error
      assert query.status == :error
      assert query.parent_id == handle_event.id
    end

    test "queries keep working when the store is down" do
      stop_child(Store)

      log = capture_log(fn -> assert [%Product{}] = TestRepo.all(Product) end)

      assert log == ""
      assert length(visualizer_handler_ids(@test_repo_event)) == 1
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

    test "no handlers are attached, nothing is recorded and queries work normally" do
      assert [%Product{name: "Widget"}] = TestRepo.all(Product)
      assert AnalyticsRepo.all(PageView) == []

      {:ok, pid} = AnalyticsRepo.start_link(name: :lvv_disabled_probe)
      Process.unlink(pid)
      Supervisor.stop(pid)

      for event <- [[:ecto, :repo, :init], @test_repo_event, @analytics_event] do
        assert visualizer_handler_ids(event) == []
      end

      assert Process.whereis(Store) == nil
      assert LiveViewVisualizer.recent_events() == []
    end
  end
end
