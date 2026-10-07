# LiveView Lifecycle Visualizer

A developer observability and visualization tool for Phoenix LiveView applications.

> **Status: Phase 4.** The visualizer automatically records LiveView and
> LiveComponent lifecycle callbacks and Ecto database queries, links queries to
> the callback that ran them, and shows everything live in a development
> dashboard at a route you choose, such as `/dev/liveview`.
> See [what is not supported yet](#not-supported-yet).

![LiveView DevTools dashboard: InventoryLive's handle_event("search") with its two Ecto queries, a failing handle_event("report") and its failing query, next to a CounterLive session](docs/images/dashboard.png)

## What is LiveView Lifecycle Visualizer?

The goal is something like browser DevTools, built for Phoenix LiveView. Add the
library, enable it in development, and see what your LiveViews are doing, which
queries each callback runs, and how long every step takes.

Instrumentation is automatic and built on the `:telemetry` events that Phoenix
LiveView and Ecto already emit. You never change your LiveViews, contexts,
schemas or repos.

## Quick start

```elixir
# mix.exs
{:liveview_visualizer, "~> 0.1.0", only: :dev}
```

```elixir
# config/dev.exs
config :liveview_visualizer,
  enabled: true
```

```elixir
# lib/my_app_web/router.ex (development only, next to live_dashboard)
if Application.compile_env(:my_app, :dev_routes) do
  import LiveViewVisualizerWeb.Router

  scope "/dev" do
    pipe_through :browser
    live_visualizer "/liveview"
  end
end
```

```bash
mix phx.server
```

Open `http://localhost:4000/dev/liveview` and use your application in another
tab. Events appear as they happen. See [Dashboard](#dashboard).

You can also inspect the raw events in IEx:

```elixir
iex> LiveViewVisualizer.recent_events()
[
  %LiveViewVisualizer.Event{id: 7, type: :ecto, name: :query, module: MyApp.Repo,
    parent_id: 6, duration: 38_200_000,
    metadata: %{repo: MyApp.Repo, source: "products", command: :select, num_rows: 12}},
  %LiveViewVisualizer.Event{id: 6, type: :live_view, name: :handle_event,
    module: MyAppWeb.InventoryLive, metadata: %{event: "search", ...}},
  %LiveViewVisualizer.Event{id: 8, type: :live_view, name: :render, ...}
]
```

Conceptually, that is:

```text
InventoryLive
│
├── handle_event("search")       45ms
│   └── Ecto query  products     38ms
│
└── render                        2ms
```

The timings are illustrative. The structure is what gets recorded: the query's
`parent_id` is the `handle_event`'s `id`, and the `render` stands on its own.

The package is not yet published to Hex. Until it is, depend on it by path or git,
for example `{:liveview_visualizer, path: "../liveview_visualizer", only: :dev}`.
Use `only: :dev` so it is never compiled into test or production builds.

## What is recorded

### LiveView and LiveComponent callbacks

| LiveView telemetry | Recorded as `type` / `name` | Since LiveView |
| --- | --- | --- |
| `[:phoenix, :live_view, :mount]` | `:live_view` / `:mount` | 1.0 |
| `[:phoenix, :live_view, :handle_params]` | `:live_view` / `:handle_params` | 1.0 |
| `[:phoenix, :live_view, :handle_event]` | `:live_view` / `:handle_event` | 1.0 |
| `[:phoenix, :live_view, :render]` | `:live_view` / `:render` | 1.0 |
| `[:phoenix, :live_component, :update]` | `:live_component` / `:update` | 1.0 |
| `[:phoenix, :live_component, :handle_event]` | `:live_component` / `:handle_event` | 1.0 |
| `[:phoenix, :live_view, :render]` with a `:component` | `:live_component` / `:render` | 1.2 |
| `[:phoenix, :live_component, :destroyed]` | `:live_component` / `:destroyed` | 1.1 |

Each event is a **completed** callback (`status: :ok`, or `:exception` if it
raised, threw or exited), with its duration from `:telemetry`. A typical page
visit produces:

```text
mount (connected?: false) → handle_params   ← HTTP request (dead render)
mount (connected?: true)  → handle_params → render   ← WebSocket
handle_event "search" → render              ← each interaction that changes assigns
```

LiveView emits no render span for the disconnected render, so none is recorded for
it. `handle_params` appears only if the LiveView defines it (or has hooks), and
`render` only when assigns changed.

### Ecto queries

Every query of every Ecto repo becomes `type: :ecto`, `name: :query`, with the
repo as `module`. Ecto has no global query event: each repo emits
`<telemetry_prefix> ++ [:query]`, where the prefix defaults to `[:my_app, :repo]`
for `MyApp.Repo`. The visualizer listens to `[:ecto, :repo, :init]`, which every
repo emits *before* its connection pool starts, and attaches that repo's query
event right then. Any number of repos, custom prefixes and repos that start
late all work, and repos already running when the visualizer starts are found
with `Ecto.Repo.all_running/0`.

- `duration` is Ecto's `total_time` (queue + query + decode). `measurements`
  holds `query_time`, `queue_time`, `decode_time` and `idle_time`.
- `status` is `:ok`, or `:error` when the database or connection reported an
  error. Your application sees exactly the same result or exception as without
  the visualizer.
- Queries from any process are recorded, including background jobs, Tasks and
  GenServers, not only LiveViews.

### Metadata kept, and what is never kept

Only structural fields are copied out of the telemetry metadata:

| Event | Keys |
| --- | --- |
| LiveView / LiveComponent | `view`, `component`, `cid`, `socket_id`, `connected?`, `route` (the router *pattern*, e.g. `"/users/:id"`), `event` (the event name), `changed?`, `force?`, `count` |
| Ecto query | `repo`, `source` (table, as reported by Ecto), `command` (`:select`, `:insert`, ... as reported by the driver), `num_rows` (a count) |
| Failures | `kind`, `exception` (the exception module), `error_code` (e.g. `:unique_violation`) |

**Never stored:** the socket, assigns, session, params, form values, URLs and
concrete paths, SQL text, query parameters, result rows, stacktraces,
`telemetry_options`, exception messages and error details. Everything is then
passed through the generic sanitizer as a second line of defence. SQL is never
parsed: if Ecto does not report a `source`, it stays `nil`.

## Correlation: which callback ran this query?

`parent_id` and `trace_id` are set only when the relationship is **certain**:

- **Queries inside a LiveView callback** get that callback as their parent. This
  covers `mount`, `handle_params`, `handle_event`, `render`, a component's
  `update` or `handle_event`, and any context function they call.
- **Nested callbacks** are linked too. A LiveComponent `update` that runs
  during a `render` has the render as its parent, and a query in that update has
  the update as its parent. `trace_id` is the outermost callback.

How it works: LiveView callbacks run inside `:telemetry.span/3` in the LiveView
process, and Ecto reports each query from the process that ran it. On the span's
`:start`, the visualizer pushes the callback onto a small stack in that process,
keyed by telemetry's own span context. It pops the entry on `:stop`/`:exception`.
A query reported in between, in the same process, is inside that callback.
The stack is bounded (8 entries), removed as soon as it is empty, and
invalidated whenever handlers are attached or detached. That last point means a
callback whose end was never observed can never become a parent. See
`LiveViewVisualizer.Context`.

These are deliberately left **without** a parent, because any link would be a
guess:

| Situation | Why no parent |
| --- | --- |
| Queries in a `Task` or another process | That process does not run the callback, and the callback may have finished by the time it queries |
| Queries in `handle_info` / `handle_async` | LiveView emits no telemetry for these callbacks |
| Background jobs, GenServers, scripts | There is no LiveView callback |
| `render` after `handle_event` | LiveView runs them one after another, not nested |

## Dashboard

```text
LiveView lifecycle  ─┐
                     ├─> correlation (parent_id) ─> trace tree, live in the browser
Ecto queries        ─┘
```

### Adding the route

`live_visualizer/2` mounts the dashboard, much like `live_dashboard`. Put it inside
the development-only block that Phoenix generates in your router:

```elixir
if Application.compile_env(:my_app, :dev_routes) do
  import LiveViewVisualizerWeb.Router

  scope "/dev" do
    pipe_through :browser
    live_visualizer "/liveview"
  end
end
```

`mix phx.new` sets `dev_routes: true` only in `config/dev.exs`, so the route does
not exist in production builds. (`if Mix.env() == :dev do ... end` in your own
router works too. The library itself never calls `Mix.env/0`.)

Options:

- `live_socket_path:` - your endpoint's LiveView socket path, if not `"/live"`
- `live_session_name:` and `as:` - change the generated `live_session` / route
  helper names. A `live_session` cannot be nested, so do not call
  `live_visualizer` inside one of yours.

The dashboard brings its own root layout, styles and LiveView client. The client
is inlined from your installed `phoenix_live_view`, so it always matches your
server and nothing is loaded from the network. It works whatever your layouts,
CSS or JavaScript look like.

### Development-only safety

- The dashboard refuses to mount, responding with a **404**, unless
  `config :liveview_visualizer, enabled: true` is set and the visualizer is running.
- There is no authentication. It is a local development tool, and the route
  should only exist in development (see above). Do not expose it in production.
- It shows only what is already stored (allowlisted, sanitized fields). Nothing
  is persisted and nothing is sent anywhere.
- Its own LiveView events are not recorded, so it never observes itself.

### Reading the dashboard

- **Header:** `● Recording` / `○ Paused`, the number of events, **Clear** and
  **Pause**.
- **Summary:** LiveViews, events, queries and errors in the current buffer.
- **LiveViews:** every observed LiveView with its event, query and error counts.
  Click one to filter.
- **Trace view:** one box per **LiveView instance**, meaning one `socket_id`,
  i.e. one LiveView on one page. An instance spans its disconnected (HTTP)
  render, its connected process and any process it is rejoined in after a crash.
  A `process <0.639.0>` divider marks each change of process. Inside, operations
  are listed in start order and children are nested **only** by `parent_id`.
  Queries appear under the callback that ran them. The `render` after a
  `handle_event` is its own row, because LiveView does not run it inside the
  handler. Events with no LiveView (Tasks, background jobs, `handle_info`) are
  listed under **Outside LiveView callbacks**.
- **Duration bars** are proportional to the slowest event in the buffer, so slow
  operations stand out.
- **Errors** are red, with `EXCEPTION` (the callback raised) or `ERROR` (a query
  returned an error) badges.
- **Event details:** click a row to see its stored fields: type, operation,
  module, repo, source, command, rows, timings, status, exception module, error
  code, pid, socket, parent and number of children. Messages, SQL, parameters and
  stacktraces are not stored, so they cannot be shown.
- **Filters and search:** LiveView, type (LiveView / LiveComponent / Ecto),
  status (OK / Error / Exception), and a free-text search over module, event
  name, source, repo, route, command and exception. A trace is shown if any of
  its events matches, and the non-matching events stay visible, dimmed, as
  context.

![Filtering by type Ecto: the queries are highlighted, their handle_event parents dimmed](docs/images/dashboard-filter.png)

- **Pause** freezes *the dashboard* only. Instrumentation and the store keep
  recording, and the header counts what arrived meanwhile. **Resume** catches up.
- **Clear** empties the visualizer's in-memory store, for every open dashboard.
  It never touches your database, your data or your LiveViews.

The screenshots are real: they were taken with headless Chromium from a small
Phoenix application using this library.

### How live updates work

```text
LiveView / Ecto ─ telemetry ─> Collector ─┬─> Store (ETS ring buffer)
                                          └─> PubSub {:event_recorded, id}
                                                      │
DashboardLive <── reads only new events ── Store.since/1
```

The collector broadcasts a tiny `{:event_recorded, id}` message on a private,
node-local `Phoenix.PubSub` server owned by the visualizer, not on your
application's PubSub. The dashboard never polls. A burst of notifications
schedules a single refresh 100ms later, which reads only the events recorded
since the previous refresh (`LiveViewVisualizer.Store.since/1`). Its window never
holds more than `max_events`.

## Not supported yet

These are **not** implemented:

- charts beyond duration bars, timelines/flame graphs, authentication, remote or
  multi-node dashboards
- SQL text (an explicit opt-in may come later), query plans / `EXPLAIN`, or
  automatic optimization advice
- `handle_info` and `handle_async`: LiveView emits no telemetry for them
- assign / state change tracking
- process, Task, GenServer and PubSub tracing, or cross-process correlation
- distributed tracing, persistence, production monitoring

## Configuration

All options are read from the application environment at runtime. The library
never calls `Mix.env/0`.

```elixir
config :liveview_visualizer,
  # Only the literal `true` enables the visualizer. Default: false.
  enabled: true,

  # Maximum number of events kept in memory (ring buffer). Default: 1000.
  max_events: 1_000,

  # Extra metadata keys to redact, on top of the built-in list. Default: [].
  redact_keys: [:ssn, "iban"],

  # Additional instrumentation modules (extension point). Default: [].
  # The LiveView and Ecto instrumentations are built in.
  instrumentations: []
```

Computed values work, for example `enabled: config_env() == :dev`. Options are
read when the application starts. Invalid values never stop your app from
booting: a warning is logged and the default is used.

### What "disabled" means

With `enabled: false` (the default), the application starts an empty supervisor and
nothing else. No ETS table, no telemetry handler, no process dictionary entries,
and no code runs in your application's processes.

### Optional dependencies

`phoenix_live_view`, `ecto` and `phoenix_pubsub` are optional dependencies.
Without them, the visualizer starts normally and the corresponding instrumentation,
the dashboard or its live notifications are skipped.

## Custom instrumentation

Any `:telemetry` event can be recorded by implementing the
`LiveViewVisualizer.Instrumentation` behaviour and listing the module under
`:instrumentations`:

```elixir
defmodule MyApp.CheckoutInstrumentation do
  @behaviour LiveViewVisualizer.Instrumentation

  alias LiveViewVisualizer.Event

  @impl true
  def events, do: [[:my_app, :checkout, :stop]]

  @impl true
  def handle_event(source, %{duration: duration, monotonic_time: stop}, metadata) do
    start = stop - duration

    Event.new!(
      type: :my_app,
      name: :checkout,
      source: source,
      duration: duration,
      monotonic_time: start,
      system_time: start + System.time_offset(),
      metadata: Map.take(metadata, [:order_id])
    )
  end
end
```

A handler may also return `{:attach, event_names}` to attach events that are only
discovered at runtime, which is how the Ecto instrumentation follows new repos.

## Architecture

```text
LiveViewVisualizer.Application
└── LiveViewVisualizer.Supervisor (one_for_one, empty when disabled)
    ├── LiveViewVisualizer.Store       owns the ETS ring buffer
    ├── LiveViewVisualizer.PubSub      private, node-local change notifications
    └── LiveViewVisualizer.Telemetry   attaches LiveView + Ecto (+ configured) instrumentations

LiveView process                               Ecto caller (any process)
  span :start ─> Context.enter (allocate id)     [prefix, :query] ─> Context.current
  ...callback runs, maybe queries...                └─> parent_id if inside a callback
  span :stop  ─> Context.exit  ─┐                     │
                                ▼                     ▼
              Telemetry handler (catches every error/throw/exit)
                └─> Instrumentation.handle_event/3   pick safe fields → %Event{}
                      └─> Collector.collect/2        sanitize
                            └─> Store.record/1        2 lock-free ETS writes
```

| Module | Responsibility |
| --- | --- |
| `LiveViewVisualizer.Config` | Reads and validates configuration, safe defaults |
| `LiveViewVisualizer.Event` | The normalized event struct shared by every source |
| `LiveViewVisualizer.Instrumentation` | Behaviour: which telemetry events to attach and how to normalize them |
| `LiveViewVisualizer.Instrumentation.LiveView` | LiveView / LiveComponent lifecycle |
| `LiveViewVisualizer.Instrumentation.Ecto` | Ecto repo queries |
| `LiveViewVisualizer.Context` | Process-local "current callback" for correlation |
| `LiveViewVisualizer.Telemetry` | Attaches and detaches handlers, isolates failures |
| `LiveViewVisualizer.Collector` | Single path into the store, always sanitizes |
| `LiveViewVisualizer.Sanitizer` | Redaction and size limits for arbitrary terms |
| `LiveViewVisualizer.Store` | Bounded, concurrent, in-memory ring buffer |
| `LiveViewVisualizer.Notifier` | Tiny "event recorded" / "cleared" notifications over a private PubSub |
| `LiveViewVisualizer.Trace` | Pure functions: events → stats, LiveView list, trees, filters, search |
| `LiveViewVisualizerWeb.Router` | `live_visualizer/2` route macro with a self-contained layout |
| `LiveViewVisualizerWeb.DashboardLive` | The dashboard itself |

Handlers run inside your processes, so they do the minimum: a few map lookups,
one small struct, a small sanitize pass and two ETS writes. A `:start` handler
only touches the process dictionary. There are no messages, no serialization and
no I/O, the socket is never copied, and result rows are never read.

### Event model

```elixir
%LiveViewVisualizer.Event{
  id: 42,                 # unique per node, allocated when the operation starts
  parent_id: 41,          # enclosing callback in the same process, or nil
  trace_id: 41,           # outermost such callback, or nil
  type: :ecto,            # :live_view | :live_component | :ecto | ... (open set)
  name: :query,           # operation within the type
  status: :ok,            # :ok | :exception (raised) | :error (reported a failure)
  module: MyApp.Repo,
  pid: #PID<0.512.0>,
  source: [:my_app, :repo, :query],
  monotonic_time: ...,    # start, native units, for ordering and offsets
  system_time: ...,       # start, native units, for display only
  duration: ...,          # native units, nil for point-in-time events
  measurements: %{},      # numeric only
  metadata: %{}           # see "Metadata kept" above
}
```

Events are stored in **completion order**: a query is stored before the callback
that ran it. Sort by `monotonic_time` for start order.

### Safety guarantees

- **Never crashes your app.** Every instrumentation call is wrapped. A failure drops
  that one event, logs once (exception module only, never the message) and the
  handler stays attached. LiveView crashes and Ecto errors behave exactly as they
  would without the visualizer (both are tested).
- **Bounded memory.** At most `max_events` events, each limited in size. The
  correlation stack is at most 8 entries per process and removed when empty.
- **No persistence.** Everything lives in ETS. Nothing is written to disk or a database.
- **No sensitive data.** Instrumentations allowlist fields, and the generic
  sanitizer additionally redacts keys containing `password`, `passwd`, `secret`,
  `token`, `csrf`, `api_key`, `apikey`, `private_key`, `auth`, `cookie`, `session`
  or `credential`, and reduces structs to their module name.

## Compatibility

Verified against the source of, and tested with:

| Library | Versions tested |
| --- | --- |
| Phoenix LiveView | 1.0.19 (Phoenix 1.7.24), 1.1.28, 1.2.12 (Phoenix 1.8.15) |
| Ecto / Ecto SQL | 3.10, 3.12, 3.13, 3.14 (PostgreSQL via Postgrex) |

Version differences are handled inside each instrumentation. For example,
`destroyed` is only attached from LiveView 1.1.0. Ecto SQL reports the `source` of
inserts, updates and deletes only from 3.11.0, so before that it is `nil`.

## Testing

```bash
mix deps.get
mix test
mix format --check-formatted
mix credo --strict
```

The Ecto integration tests need PostgreSQL. By default they use
`ecto://postgres:postgres@localhost:5432/liveview_visualizer_test`, which is
created automatically. Override it with `LVV_DATABASE_URL`. If the database is
unreachable, tests tagged `:postgres` are excluded and a notice is printed.

The suite includes real Phoenix LiveView and PostgreSQL integration tests:
lifecycle order, components, query correlation (and its absence for Tasks,
`handle_info` and background processes), multiple repos, metadata safety,
failures, disabled mode, a separate VM booted with neither LiveView nor Ecto, and
the dashboard: trees, filters, search, details, pause, clear, live updates,
404 when disabled, and what it can and cannot render.

## Roadmap

- **Phase 1 – Foundation**: config, event model, store, sanitizer, telemetry plumbing.
- **Phase 2 – LiveView lifecycle instrumentation.**
- **Phase 3 – Ecto query instrumentation and callback correlation.**
- **Phase 4 – Live developer dashboard** (this release).
- **Later**: `handle_info` / `handle_async`, assigns diffs, processes and tasks,
  PubSub, opt-in SQL view.

Not planned: production monitoring, persistence or distributed tracing. This is a
development tool.

## License

MIT. See the `LICENSE` file.
