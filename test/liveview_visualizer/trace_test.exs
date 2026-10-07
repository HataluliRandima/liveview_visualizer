defmodule LiveViewVisualizer.TraceTest do
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.{Event, Trace}
  alias LiveViewVisualizer.Trace.Filters

  @lv MyAppWeb.InventoryLive
  @other_lv MyAppWeb.CounterLive

  defp lv(name, attrs \\ []) do
    {meta, attrs} = Keyword.pop(attrs, :metadata, %{})
    {view, attrs} = Keyword.pop(attrs, :view, @lv)
    {socket, attrs} = Keyword.pop(attrs, :socket_id, "phx-inventory")

    Event.new!(
      [
        type: :live_view,
        name: name,
        module: view,
        duration: 1_000,
        metadata: Map.merge(%{view: view, socket_id: socket}, meta)
      ] ++ attrs
    )
  end

  defp query(parent, attrs \\ []) do
    {meta, attrs} = Keyword.pop(attrs, :metadata, %{})

    Event.new!(
      [
        type: :ecto,
        name: :query,
        module: MyApp.Repo,
        duration: 500,
        parent_id: parent && parent.id,
        trace_id: parent && parent.id,
        metadata: Map.merge(%{repo: MyApp.Repo, source: "products", command: :select}, meta)
      ] ++ attrs
    )
  end

  defp ids(trees), do: Enum.map(trees, & &1.event.id)
  defp group(model, key), do: Enum.find(model.groups, &(&1.key == key))

  describe "trees" do
    test "children are nested under their parent_id, in start order" do
      event = lv(:handle_event, metadata: %{event: "search"})
      q1 = query(event)
      q2 = query(event)

      [group] = Trace.build([q2, q1, event]).groups
      [root] = group.roots

      assert root.event.id == event.id
      assert ids(root.children) == [q1.id, q2.id]
      assert Enum.all?(root.children, &(&1.children == []))
    end

    test "events without a parent are roots, and nothing is inferred from timing" do
      handle_event = lv(:handle_event, metadata: %{event: "inc"})
      render = lv(:render)

      [group] = Trace.build([handle_event, render]).groups

      # render runs right after handle_event, but has no parent_id: it stays a root.
      assert ids(group.roots) == [handle_event.id, render.id]
      assert Enum.all?(group.roots, &(&1.children == []))
    end

    test "an event whose parent was evicted is shown as an orphaned root" do
      parent = lv(:handle_event)
      child = query(parent)

      [root] = group(Trace.build([child]), :other).roots

      assert root.event.id == child.id
      assert root.orphan?
    end

    test "deep nesting follows parent_id at every level" do
      render = lv(:render)

      update =
        Event.new!(
          type: :live_component,
          name: :update,
          module: MyAppWeb.StockComponent,
          parent_id: render.id,
          trace_id: render.id,
          metadata: %{view: @lv, socket_id: "phx-inventory"}
        )

      q = query(update)

      [%{roots: [root]}] = Trace.build([q, update, render]).groups
      assert [%{event: %{id: update_id}, children: [%{event: %{id: q_id}}]}] = root.children
      assert {update_id, q_id} == {update.id, q.id}
    end
  end

  describe "groups" do
    test "roots are grouped by socket_id, and the other roots are kept apart" do
      a = lv(:mount, socket_id: "phx-a")
      b = lv(:mount, view: @other_lv, socket_id: "phx-b")
      background = query(nil)

      model = Trace.build([a, b, background])

      assert group(model, {:live_view, "phx-a"}).view == @lv
      assert group(model, {:live_view, "phx-b"}).view == @other_lv
      assert ids(group(model, :other).roots) == [background.id]
      assert group(model, :other).view == nil
    end

    test "a LiveView instance can span several processes, with each change marked" do
      task = Task.async(fn -> lv(:mount, metadata: %{connected?: false}) end)
      dead = Task.await(task)
      connected = lv(:mount, metadata: %{connected?: true})
      render = lv(:render)

      group = group(Trace.build([dead, connected, render]), {:live_view, "phx-inventory"})

      assert group.pids == [dead.pid, self()]
      assert Enum.map(group.roots, & &1.new_process?) == [true, true, false]
    end

    test "groups with the most recent activity come first" do
      old = lv(:mount, socket_id: "phx-old", monotonic_time: 0)
      new = lv(:mount, socket_id: "phx-new", monotonic_time: 1_000_000)

      assert Enum.map(Trace.build([old, new]).groups, & &1.key) ==
               [{:live_view, "phx-new"}, {:live_view, "phx-old"}]
    end

    test "only the most recent roots are kept per group, and the rest are counted" do
      events = for i <- 1..5, do: lv(:render, monotonic_time: i)

      [group] = Trace.build(events, %Filters{}, max_roots: 2).groups

      assert ids(group.roots) == events |> Enum.take(-2) |> Enum.map(& &1.id)
      assert group.hidden_roots == 3
    end
  end

  describe "stats and LiveView summaries" do
    test "are derived from the events" do
      event = lv(:handle_event)
      ok_query = query(event)
      failed_query = query(event, status: :error)
      other = lv(:mount, view: @other_lv, socket_id: "phx-counter", status: :exception)
      background = query(nil)

      model = Trace.build([event, ok_query, failed_query, other, background])

      assert model.stats == %{live_views: 2, events: 5, queries: 3, errors: 2}

      assert model.live_views == [
               %{view: @lv, events: 3, queries: 2, errors: 1},
               %{view: @other_lv, events: 1, queries: 0, errors: 1}
             ]

      assert model.child_counts == %{event.id => 2}
    end
  end

  describe "filters" do
    setup do
      event = lv(:handle_event, metadata: %{event: "search"})
      q = query(event, metadata: %{source: "stock_levels"})
      render = lv(:render)
      failed = lv(:handle_event, status: :exception, metadata: %{event: "save"})
      counter = lv(:mount, view: @other_lv, socket_id: "phx-counter")
      background = query(nil, metadata: %{repo: MyApp.AnalyticsRepo, source: "page_views"})

      %{
        events: [event, q, render, failed, counter, background],
        event: event,
        q: q,
        failed: failed
      }
    end

    defp visible(events, filters) do
      events
      |> Trace.build(filters)
      |> Map.fetch!(:groups)
      |> Enum.flat_map(& &1.roots)
      |> Enum.flat_map(&flatten/1)
    end

    defp flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]
    defp matching(nodes), do: nodes |> Enum.filter(& &1.match?) |> Enum.map(& &1.event.id)

    test "type keeps trees containing a match and marks the non-matching context", ctx do
      nodes = visible(ctx.events, %Filters{type: :ecto})

      assert ctx.event.id in Enum.map(nodes, & &1.event.id)
      assert Enum.sort(matching(nodes)) == Enum.sort([ctx.q.id, List.last(ctx.events).id])
    end

    test "status selects failed events", %{events: events, failed: failed} do
      assert matching(visible(events, %Filters{status: :exception})) == [failed.id]
    end

    test "view selects one LiveView's groups", %{events: events} do
      nodes = visible(events, %Filters{view: @other_lv})
      assert Enum.map(nodes, & &1.event.module) == [@other_lv]
    end

    test "search matches module, event name, source and repo", %{events: events} = ctx do
      assert matching(visible(events, %Filters{query: "counterlive"})) == [Enum.at(events, 4).id]
      assert matching(visible(events, %Filters{query: "SEARCH"})) == [ctx.event.id]
      assert matching(visible(events, %Filters{query: "stock_levels"})) == [ctx.q.id]
      assert matching(visible(events, %Filters{query: "AnalyticsRepo"})) == [List.last(events).id]
      assert visible(events, %Filters{query: "no-such-thing"}) == []
    end

    test "search ignores metadata that is not displayed" do
      event = lv(:mount, metadata: %{secret_note: "findme"})
      assert visible([event], %Filters{query: "findme"}) == []
    end

    test "Filters.active?/1" do
      refute Filters.active?(%Filters{})
      assert Filters.active?(%Filters{query: "x"})
      assert Filters.active?(%Filters{type: :ecto})
    end
  end
end
