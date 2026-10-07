if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule LiveViewVisualizerWeb.DashboardLive do
    @moduledoc """
    The LiveView DevTools dashboard.

    Mount it with `LiveViewVisualizerWeb.Router.live_visualizer/2`. It refuses to
    mount (404) unless the visualizer is enabled and running.

    ## Data flow

    The dashboard never polls. It subscribes to `LiveViewVisualizer.Notifier`.
    Each `{:event_recorded, id}` notification marks the view as stale and
    schedules one refresh 100ms later, so a burst of events causes a single
    refresh. A refresh reads only the events recorded since the last one
    (`LiveViewVisualizer.Store.since/1`) and appends them to a window bounded by
    the store's capacity. Everything shown is then derived from that window by
    `LiveViewVisualizer.Trace`.

    ## Pause and Clear

      * **Pause** stops *this dashboard* from updating. Instrumentation and the
        store keep recording, and the number of events received while paused is
        shown. Resuming reloads the current store contents.
      * **Clear** empties the visualizer's in-memory store (and every open
        dashboard). It never touches the application, its database or its
        processes.
    """

    use Phoenix.LiveView

    alias LiveViewVisualizer.{Config, Notifier, Store, Trace}
    alias LiveViewVisualizer.Trace.Filters
    alias LiveViewVisualizerWeb.{DisabledError, Format}

    @refresh_after 100

    @types %{"live_view" => :live_view, "live_component" => :live_component, "ecto" => :ecto}
    @statuses %{"ok" => :ok, "error" => :error, "exception" => :exception}

    @impl true
    def mount(_params, _session, socket) do
      if not Config.enabled?() or Store.capacity() == nil, do: raise(DisabledError)

      if connected?(socket), do: Notifier.subscribe()

      {seq, events} = Store.since(0)

      {:ok,
       socket
       |> assign(
         page_title: "LiveView DevTools",
         seq: seq,
         events: events,
         filters: %Filters{},
         paused?: false,
         pending: 0,
         refresh_scheduled?: false,
         selected: nil
       )
       |> build()}
    end

    @impl true
    def handle_info({:event_recorded, _id}, %{assigns: %{paused?: true}} = socket),
      do: {:noreply, update(socket, :pending, &(&1 + 1))}

    def handle_info({:event_recorded, _id}, %{assigns: %{refresh_scheduled?: true}} = socket),
      do: {:noreply, socket}

    def handle_info({:event_recorded, _id}, socket) do
      Process.send_after(self(), :refresh, @refresh_after)
      {:noreply, assign(socket, refresh_scheduled?: true)}
    end

    def handle_info(:events_cleared, %{assigns: %{paused?: true}} = socket),
      do: {:noreply, socket}

    def handle_info(:events_cleared, socket), do: {:noreply, reset(socket)}

    def handle_info(:refresh, socket) do
      socket = assign(socket, refresh_scheduled?: false)
      if socket.assigns.paused?, do: {:noreply, socket}, else: {:noreply, refresh(socket)}
    end

    @impl true
    def handle_event("filter", params, socket) do
      filters = %Filters{
        view: lookup_view(socket, params["view"]),
        type: Map.get(@types, params["type"]),
        status: Map.get(@statuses, params["status"]),
        query:
          params |> Map.get("query", "") |> to_string() |> String.trim() |> String.slice(0, 100)
      }

      {:noreply, socket |> assign(filters: filters) |> build()}
    end

    def handle_event("select_view", %{"view" => view}, socket) do
      filters = %{socket.assigns.filters | view: lookup_view(socket, view)}
      {:noreply, socket |> assign(filters: filters) |> build()}
    end

    def handle_event("select", %{"id" => id}, socket) do
      case Integer.parse(to_string(id)) do
        {id, ""} -> {:noreply, assign(socket, selected: id)}
        _ -> {:noreply, socket}
      end
    end

    def handle_event("close_details", _params, socket),
      do: {:noreply, assign(socket, selected: nil)}

    def handle_event("clear", _params, socket) do
      :ok = LiveViewVisualizer.clear_events()
      {:noreply, reset(socket)}
    end

    def handle_event("toggle_pause", _params, %{assigns: %{paused?: true}} = socket) do
      {seq, events} = Store.since(0)

      {:noreply,
       socket
       |> assign(paused?: false, pending: 0, seq: seq, events: events)
       |> build()}
    end

    def handle_event("toggle_pause", _params, socket),
      do: {:noreply, assign(socket, paused?: true, pending: 0)}

    defp refresh(socket) do
      %{seq: seq, events: events} = socket.assigns

      case Store.since(seq) do
        # The store restarted: its sequence numbers started over.
        {new_seq, _} when new_seq < seq ->
          {new_seq, events} = Store.since(0)
          socket |> assign(seq: new_seq, events: events) |> build()

        {^seq, []} ->
          socket

        {new_seq, new_events} ->
          window = Store.capacity() || length(events) + length(new_events)
          events = Enum.take(events ++ new_events, -window)
          socket |> assign(seq: new_seq, events: events) |> build()
      end
    end

    defp reset(socket), do: socket |> assign(events: [], selected: nil) |> build()

    defp build(socket),
      do: assign(socket, model: Trace.build(socket.assigns.events, socket.assigns.filters))

    # Filter values arrive as strings from the browser. They are only ever
    # matched against modules already observed, never turned into atoms.
    defp lookup_view(socket, value) when is_binary(value) and value != "" do
      Enum.find_value(socket.assigns.model.live_views, fn %{view: view} ->
        if inspect(view) == value, do: view
      end)
    end

    defp lookup_view(_socket, _value), do: nil

    @impl true
    def render(assigns) do
      selected_event = assigns.selected && Map.get(assigns.model.index, assigns.selected)
      filtering? = Filters.active?(assigns.filters)

      assigns =
        assign(assigns, selected_event: selected_event, filtering?: filtering?, css: css())

      ~H"""
      <style><%= Phoenix.HTML.raw(@css) %></style>
      <div class="lvv" id="lvv-dashboard">
        <header class="lvv-header">
          <h1 class="lvv-title">LIVEVIEW DEVTOOLS</h1>
          <span :if={!@paused?} class="lvv-recording" id="lvv-status">● Recording</span>
          <span :if={@paused?} class="lvv-paused" id="lvv-status">
            ○ Paused<span :if={@pending > 0}> · {@pending} new</span>
          </span>
          <span class="lvv-count" id="lvv-event-count">Events: {@model.stats.events}</span>
          <span class="lvv-spacer"></span>
          <button type="button" class="lvv-button" id="lvv-clear" phx-click="clear">Clear</button>
          <button type="button" class="lvv-button" id="lvv-pause" phx-click="toggle_pause">
            {if @paused?, do: "Resume", else: "Pause"}
          </button>
        </header>

        <section class="lvv-stats" id="lvv-stats">
          <div><span>LiveViews</span><strong id="lvv-stat-live-views">{@model.stats.live_views}</strong></div>
          <div><span>Events</span><strong id="lvv-stat-events">{@model.stats.events}</strong></div>
          <div><span>Queries</span><strong id="lvv-stat-queries">{@model.stats.queries}</strong></div>
          <div class={if @model.stats.errors > 0, do: "lvv-has-errors"}>
            <span>Errors</span><strong id="lvv-stat-errors">{@model.stats.errors}</strong>
          </div>
        </section>

        <div class="lvv-layout">
          <aside class="lvv-sidebar">
            <form id="lvv-filters" phx-change="filter" phx-submit="filter" class="lvv-filters">
              <label>
                Search
                <input
                  type="search"
                  name="query"
                  value={@filters.query}
                  placeholder="module, event, source, repo…"
                  phx-debounce="150"
                  autocomplete="off"
                />
              </label>
              <label>
                LiveView
                <select name="view">
                  <option value="">All</option>
                  <option
                    :for={lv <- @model.live_views}
                    value={inspect(lv.view)}
                    selected={@filters.view == lv.view}
                  >
                    {Format.short_module(lv.view)}
                  </option>
                </select>
              </label>
              <label>
                Type
                <select name="type">
                  <option value="">All</option>
                  <option value="live_view" selected={@filters.type == :live_view}>LiveView</option>
                  <option value="live_component" selected={@filters.type == :live_component}>
                    LiveComponent
                  </option>
                  <option value="ecto" selected={@filters.type == :ecto}>Ecto</option>
                </select>
              </label>
              <label>
                Status
                <select name="status">
                  <option value="">All</option>
                  <option value="ok" selected={@filters.status == :ok}>OK</option>
                  <option value="error" selected={@filters.status == :error}>Error</option>
                  <option value="exception" selected={@filters.status == :exception}>Exception</option>
                </select>
              </label>
            </form>

            <h2 class="lvv-heading">LiveViews</h2>
            <p :if={@model.live_views == []} class="lvv-muted">None observed yet.</p>
            <ul class="lvv-views" id="lvv-live-views">
              <li :for={lv <- @model.live_views}>
                <button
                  type="button"
                  phx-click="select_view"
                  phx-value-view={if @filters.view == lv.view, do: "", else: inspect(lv.view)}
                  class={["lvv-view", @filters.view == lv.view && "lvv-active"]}
                  title={inspect(lv.view)}
                >
                  <span class="lvv-view-name">{Format.short_module(lv.view)}</span>
                  <span class="lvv-view-meta">
                    {lv.events} events · {lv.queries} queries<span :if={lv.errors > 0} class="lvv-error-text"> · {lv.errors} errors</span>
                  </span>
                </button>
              </li>
            </ul>
          </aside>

          <main class="lvv-main" id="lvv-traces">
            <div :if={@model.stats.events == 0} class="lvv-empty" id="lvv-empty">
              <p><strong>No LiveView activity yet.</strong></p>
              <p>
                Interact with your application and lifecycle events will appear here automatically.
              </p>
            </div>

            <div :if={@model.stats.events > 0 and @model.groups == []} class="lvv-empty">
              <p>No events match the current filters.</p>
            </div>

            <section
              :for={group <- @model.groups}
              class="lvv-group"
              id={group_dom_id(group)}
            >
              <header class="lvv-group-header">
                <span :if={group.key == :other} class="lvv-group-title">Outside LiveView callbacks</span>
                <span :if={group.key != :other} class="lvv-group-title" title={inspect(group.view)}>
                  {Format.short_module(group.view)}
                </span>
                <span :if={group.socket_id} class="lvv-muted">#{group.socket_id}</span>
                <span class="lvv-muted lvv-pids" title={Enum.map_join(group.pids, ", ", &pid_text/1)}>
                  {length(group.pids)} {if length(group.pids) == 1, do: "process", else: "processes"}
                </span>
              </header>
              <p :if={group.hidden_roots > 0} class="lvv-muted lvv-hidden">
                {group.hidden_roots} older operations not shown
              </p>
              <ul class="lvv-tree">
                <.tree_node
                  :for={root <- group.roots}
                  node={root}
                  max={@model.max_duration}
                  selected={@selected}
                  filtering?={@filtering?}
                  root?={true}
                />
              </ul>
            </section>
          </main>

          <aside class="lvv-details" id="lvv-details">
            <div :if={@selected_event == nil} class="lvv-muted lvv-details-empty">
              Select an event to see its details.
            </div>
            <div :if={@selected_event}>
              <header class="lvv-details-header">
                <h2 class="lvv-heading">Event details</h2>
                <button type="button" class="lvv-close" phx-click="close_details" aria-label="Close">
                  ×
                </button>
              </header>
              <dl class="lvv-dl">
                <%= for {label, value} <- Format.details(@selected_event, @model.index, @model.child_counts) do %>
                  <dt>{label}</dt>
                  <dd class={if label == "Status" and value != "OK", do: "lvv-error-text"}>{value}</dd>
                <% end %>
              </dl>
            </div>
            <div :if={@selected && @selected_event == nil} class="lvv-muted lvv-details-empty">
              That event is no longer in the buffer.
            </div>
          </aside>
        </div>
      </div>
      """
    end

    attr(:node, :map, required: true)
    attr(:max, :integer, required: true)
    attr(:selected, :any, required: true)
    attr(:filtering?, :boolean, required: true)
    attr(:root?, :boolean, default: false)

    defp tree_node(assigns) do
      ~H"""
      <li :if={@root? and @node.new_process?} class="lvv-process" aria-hidden="true">
        process {pid_text(@node.event.pid)}
      </li>
      <li
        id={"lvv-node-#{@node.event.id}"}
        class={[
          "lvv-node",
          @root? && "lvv-root",
          @node.event.status != :ok && "lvv-failed",
          @filtering? and not @node.match? && "lvv-dim"
        ]}
        data-type={@node.event.type}
        data-status={@node.event.status}
        data-role={if @root?, do: "root", else: "child"}
      >
        <div
          class={["lvv-row", @selected == @node.event.id && "lvv-selected"]}
          phx-click="select"
          phx-value-id={@node.event.id}
          title={inspect(@node.event.module)}
        >
          <span class={["lvv-kind", "lvv-kind-#{@node.event.type}"]}>{kind(@node.event)}</span>
          <span class="lvv-label">{Format.label(@node.event)}</span>
          <span :if={@node.orphan?} class="lvv-muted lvv-orphan" title="Its parent is no longer in the buffer">
            ↖ parent evicted
          </span>
          <span :if={@node.event.status != :ok} class="lvv-badge">
            {Format.status_name(@node.event.status)}
          </span>
          <span class="lvv-bar">
            <span style={"width: #{Format.bar_width(@node.event.duration, @max)}%"}></span>
          </span>
          <span class="lvv-duration">{Format.duration(@node.event.duration)}</span>
        </div>
        <ul :if={@node.children != []}>
          <.tree_node
            :for={child <- @node.children}
            node={child}
            max={@max}
            selected={@selected}
            filtering?={@filtering?}
          />
        </ul>
      </li>
      """
    end

    defp kind(%{type: :live_view}), do: "LV"
    defp kind(%{type: :live_component}), do: "LC"
    defp kind(%{type: :ecto}), do: "DB"
    defp kind(%{type: type}), do: type |> to_string() |> String.slice(0, 2) |> String.upcase()

    defp pid_text(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
    defp pid_text(_pid), do: "?"

    defp group_dom_id(%{key: {:live_view, socket_id}}), do: "lvv-group-#{socket_id}"
    defp group_dom_id(%{key: :other}), do: "lvv-group-other"

    # Styles are part of the template so the dashboard looks the same with the
    # bundled root layout or inside an application's own layout. Every class is
    # prefixed with "lvv-".
    defp css do
      """
      .lvv-body { margin: 0; }
      .lvv {
        --bg: #ffffff; --panel: #f6f7f9; --border: #dde1e6; --text: #1f2328; --muted: #6a737d;
        --accent: #6e40c9; --db: #0b7285; --lc: #9c36b5; --lv: #6e40c9; --error: #d1242f;
        --error-bg: #ffebe9; --bar: #8c6cd9; --selected: #ede7fb; --dim: 0.4;
        font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif;
        color: var(--text); background: var(--bg); min-height: 100vh; box-sizing: border-box;
        display: flex; flex-direction: column;
      }
      @media (prefers-color-scheme: dark) {
        .lvv {
          --bg: #16181d; --panel: #1d2026; --border: #30353d; --text: #e6e8eb; --muted: #8b949e;
          --accent: #a78bfa; --db: #3bc9db; --lc: #e599f7; --lv: #a78bfa; --error: #ff7b72;
          --error-bg: #3d1f22; --bar: #7c5cd6; --selected: #2b2540;
        }
      }
      .lvv *, .lvv *::before, .lvv *::after { box-sizing: border-box; }
      .lvv button, .lvv input, .lvv select { font: inherit; color: inherit; }
      .lvv-header { display: flex; align-items: center; gap: 14px; padding: 8px 16px;
        border-bottom: 1px solid var(--border); background: var(--panel); flex-wrap: wrap; }
      .lvv-title { font-size: 13px; letter-spacing: .08em; margin: 0; font-weight: 700; }
      .lvv-recording { color: #1a7f37; font-weight: 600; }
      .lvv-paused { color: var(--muted); font-weight: 600; }
      .lvv-count { color: var(--muted); font-variant-numeric: tabular-nums; }
      .lvv-spacer { flex: 1; }
      .lvv-button { border: 1px solid var(--border); background: var(--bg); border-radius: 4px;
        padding: 3px 12px; cursor: pointer; }
      .lvv-button:hover { border-color: var(--accent); }
      .lvv-stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1px;
        background: var(--border); border-bottom: 1px solid var(--border); }
      .lvv-stats > div { background: var(--bg); padding: 8px 16px; display: flex; flex-direction: column; }
      .lvv-stats span { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .06em; }
      .lvv-stats strong { font-size: 20px; font-variant-numeric: tabular-nums; }
      .lvv-has-errors strong { color: var(--error); }
      .lvv-layout { flex: 1; display: grid; grid-template-columns: 250px minmax(0, 1fr) 320px; min-height: 0; }
      .lvv-sidebar, .lvv-details { background: var(--panel); padding: 12px; overflow: auto; }
      .lvv-sidebar { border-right: 1px solid var(--border); }
      .lvv-details { border-left: 1px solid var(--border); }
      .lvv-main { overflow: auto; padding: 8px 16px 24px; }
      .lvv-heading { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted);
        margin: 16px 0 6px; font-weight: 600; }
      .lvv-muted { color: var(--muted); }
      .lvv-filters { display: flex; flex-direction: column; gap: 8px; }
      .lvv-filters label { display: flex; flex-direction: column; gap: 2px; font-size: 11px; color: var(--muted); }
      .lvv-filters input, .lvv-filters select { padding: 4px 6px; border: 1px solid var(--border);
        border-radius: 4px; background: var(--bg); font-size: 13px; }
      .lvv-views { list-style: none; margin: 0; padding: 0; }
      .lvv-view { display: flex; flex-direction: column; width: 100%; text-align: left; border: 0;
        background: none; padding: 5px 6px; border-radius: 4px; cursor: pointer; }
      .lvv-view:hover { background: var(--selected); }
      .lvv-view.lvv-active { background: var(--selected); box-shadow: inset 2px 0 var(--accent); }
      .lvv-view-name { font-weight: 600; }
      .lvv-view-meta { color: var(--muted); font-size: 12px; }
      .lvv-error-text { color: var(--error); font-weight: 600; }
      .lvv-empty { padding: 48px 16px; text-align: center; color: var(--muted); }
      .lvv-group { margin-top: 12px; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
      .lvv-group-header { display: flex; gap: 10px; align-items: baseline; padding: 6px 10px;
        background: var(--panel); border-bottom: 1px solid var(--border); flex-wrap: wrap; }
      .lvv-group-title { font-weight: 700; }
      .lvv-pids { margin-left: auto; font-size: 12px; }
      .lvv-hidden { margin: 4px 10px; font-size: 12px; }
      .lvv-process { color: var(--muted); font-size: 11px; padding: 4px 10px 1px 40px; }
      .lvv-process:not(:first-child) { border-top: 1px dashed var(--border); margin-top: 3px; }
      .lvv-tree, .lvv-tree ul { list-style: none; margin: 0; padding: 0; }
      .lvv-tree { padding: 4px 0; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
      .lvv-tree ul { margin-left: 18px; border-left: 1px solid var(--border); }
      .lvv-tree ul > li { position: relative; }
      .lvv-tree ul > li::before { content: ""; position: absolute; left: 0; top: 11px; width: 10px;
        border-top: 1px solid var(--border); }
      .lvv-tree ul > li > .lvv-row { padding-left: 14px; }
      .lvv-row { display: flex; align-items: center; gap: 8px; padding: 1px 10px; cursor: pointer;
        white-space: nowrap; min-width: 0; }
      .lvv-row:hover { background: var(--selected); }
      .lvv-row.lvv-selected { background: var(--selected); box-shadow: inset 2px 0 var(--accent); }
      .lvv-kind { flex: 0 0 22px; font-size: 10px; font-weight: 700; text-align: center; }
      .lvv-kind-live_view { color: var(--lv); }
      .lvv-kind-live_component { color: var(--lc); }
      .lvv-kind-ecto { color: var(--db); }
      .lvv-label { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
      .lvv-orphan { font-size: 11px; }
      .lvv-badge { font-size: 10px; font-weight: 700; color: var(--error); border: 1px solid var(--error);
        border-radius: 3px; padding: 0 4px; }
      .lvv-failed > .lvv-row { background: var(--error-bg); }
      .lvv-failed > .lvv-row .lvv-label { color: var(--error); }
      .lvv-bar { flex: 0 0 32%; height: 8px; }
      .lvv-bar > span { display: block; height: 100%; background: var(--bar); border-radius: 2px; min-width: 1px; }
      .lvv-failed > .lvv-row .lvv-bar > span { background: var(--error); }
      .lvv-duration { flex: 0 0 64px; text-align: right; font-variant-numeric: tabular-nums; }
      .lvv-dim > .lvv-row { opacity: var(--dim); }
      .lvv-details-header { display: flex; align-items: center; justify-content: space-between; }
      .lvv-close { border: 0; background: none; font-size: 18px; cursor: pointer; color: var(--muted); }
      .lvv-dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 4px 12px; margin: 0; }
      .lvv-dl dt { color: var(--muted); }
      .lvv-dl dd { margin: 0; overflow-wrap: anywhere; font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; }
      .lvv-details-empty { padding-top: 16px; }
      @media (max-width: 1100px) {
        .lvv-layout { grid-template-columns: 220px minmax(0, 1fr); }
        .lvv-details { grid-column: 1 / -1; border-left: 0; border-top: 1px solid var(--border); }
      }
      @media (max-width: 760px) {
        .lvv-layout { grid-template-columns: minmax(0, 1fr); }
        .lvv-sidebar { border-right: 0; border-bottom: 1px solid var(--border); }
        .lvv-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
        .lvv-row .lvv-bar, .lvv-row .lvv-orphan { display: none; }
        .lvv-label { flex: 1 1 auto; }
      }
      """
    end
  end
end
