# LiveView Lifecycle Visualizer

A developer observability and visualization tool for Phoenix LiveView applications.

> **Status: Phase 2.** The visualizer automatically records the lifecycle of your
> LiveViews and LiveComponents (`mount`, `handle_params`, `handle_event`, `render`,
> component `update` / `handle_event` / `destroyed`) into a bounded in-memory store.
> There is **no dashboard yet**. Events are inspected with
> `LiveViewVisualizer.recent_events/1`. See [what is not supported yet](#not-supported-yet).

## What is LiveView Lifecycle Visualizer?

The goal is something like browser DevTools, built for Phoenix LiveView. Add the
library, enable it in development, and see what your LiveViews are doing, how long
each step takes, and eventually how those steps relate to database queries,
processes and PubSub messages.

Instrumentation is automatic and built on the `:telemetry` events Phoenix LiveView
already emits. You never add tracking calls to your LiveView modules.

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

```bash
iex -S mix phx.server
```

Use your app in the browser, then in IEx:

```elixir
iex> LiveViewVisualizer.recent_events()
[
  %LiveViewVisualizer.Event{type: :live_view, name: :mount, module: MyAppWeb.InventoryLive,
    status: :ok, duration: 1_412_000, metadata: %{connected?: true, route: "/inventory", ...}},
  %LiveViewVisualizer.Event{type: :live_view, name: :render, ...},
  %LiveViewVisualizer.Event{type: :live_view, name: :handle_event,
    metadata: %{event: "search", ...}},
  %LiveViewVisualizer.Event{type: :live_view, name: :render, ...}
]
```

Conceptually, that is:

```text
InventoryLive
├── mount          1.4ms
├── render         2.1ms
├── handle_event   5.7ms   "search"
└── render         1.8ms
```

The package is not yet published to Hex. Until it is, depend on it by path or git,
for example `{:liveview_visualizer, path: "../liveview_visualizer", only: :dev}`.
Use `only: :dev` so it is never compiled into test or production builds.

## What is recorded

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

Each event is a **completed** operation. Only the `:stop` and `:exception` events of
each telemetry span are used, never `:start`:

- `status` is `:ok`, or `:exception` if the callback raised, threw or exited.
- `duration` is the span duration from `:telemetry`, in native time units. Use
  `LiveViewVisualizer.Event.duration(event, :microsecond)` to convert it.
- `module` is the LiveView, or the LiveComponent for component events.
- `pid` is the process that ran the callback: the LiveView process when
  connected, the HTTP request process for the disconnected render.

A typical page visit produces:

```text
mount (connected?: false) → handle_params  ← HTTP request (dead render)
mount (connected?: true)  → handle_params → render  ← WebSocket (connected render)
handle_event "inc" → render                ← each interaction that changes assigns
```

LiveView does not emit a render span for the disconnected (HTTP) render, so none is
recorded for it. `handle_params` only appears if the LiveView defines it (or has
lifecycle hooks), and `render` only appears when assigns changed.

Events are stored in **completion order**. Sort by `monotonic_time` for start
order, which differs only for nested operations such as component updates during
a render.

### Metadata kept, and what is never kept

Only structural fields are copied out of the telemetry metadata:

| Key | Meaning |
| --- | --- |
| `view` | the LiveView module |
| `component`, `cid` | the LiveComponent module and its id, or `nil` |
| `socket_id` | the LiveView's DOM id, the same for its dead and connected mounts |
| `connected?` | `mount` / `handle_params`: whether the socket is connected |
| `route` | `mount` / `handle_params`: the router pattern, e.g. `"/users/:id"` |
| `event` | `handle_event`: the event name, kept as a string |
| `changed?`, `force?` | `render` flags |
| `count` | `update`: number of components updated in one batch |
| `kind`, `exception` | on failure: `:error`/`:throw`/`:exit` and the exception module |

**Never stored:** the socket, assigns, session, params, form values, the request
URL or concrete path, the query string, exception messages, exit reasons and
stacktraces. The route is stored as its *pattern* (`/reset/:token`), so tokens in
URLs never reach the store. Everything is then passed through the generic
sanitizer as a second line of defence.

## Not supported yet

These are planned for later phases and are **not** implemented:

- `handle_info` and `handle_async`: LiveView emits no telemetry for them
- assign / state change tracking
- Ecto query instrumentation
- process, Task and GenServer tracing
- PubSub tracing
- parent/child correlation between events (`parent_id` / `trace_id` are `nil`)
- a dashboard UI

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
  # The LiveView instrumentation is built in and needs no configuration.
  instrumentations: []
```

Computed values work, for example `enabled: config_env() == :dev` in a shared
config file. Options are read when the application starts. Invalid values never
stop your app from booting: a warning is logged and the default is used.

### What "disabled" means

With `enabled: false` (the default), the application starts an empty supervisor and
nothing else. No ETS table is created, no telemetry handler is attached, and no
code runs in your application's processes.

### Without Phoenix LiveView

`phoenix_live_view` is an optional dependency. If your application does not use it,
the visualizer starts normally, the LiveView instrumentation is skipped, and the
store and custom instrumentations keep working.

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

## Architecture

```text
LiveViewVisualizer.Application
└── LiveViewVisualizer.Supervisor (one_for_one, empty when disabled)
    ├── LiveViewVisualizer.Store       owns the ETS ring buffer
    └── LiveViewVisualizer.Telemetry   attaches Instrumentation.LiveView + configured ones

LiveView process
  └─> :telemetry span :stop / :exception
        └─> Telemetry handler (catches every error/throw/exit)
              └─> Instrumentation.LiveView.handle_event/3   pick safe fields → %Event{}
                    └─> Collector.collect/2                 sanitize
                          └─> Store.record/1                 2 lock-free ETS writes
```

| Module | Responsibility |
| --- | --- |
| `LiveViewVisualizer.Config` | Reads and validates configuration, safe defaults |
| `LiveViewVisualizer.Event` | The normalized event struct shared by every source |
| `LiveViewVisualizer.Instrumentation` | Behaviour: which telemetry events to attach and how to normalize them |
| `LiveViewVisualizer.Instrumentation.LiveView` | Built-in LiveView / LiveComponent lifecycle instrumentation |
| `LiveViewVisualizer.Telemetry` | Attaches and detaches handlers, isolates failures |
| `LiveViewVisualizer.Collector` | Single path into the store, always sanitizes |
| `LiveViewVisualizer.Sanitizer` | Redaction and size limits for arbitrary terms |
| `LiveViewVisualizer.Store` | Bounded, concurrent, in-memory ring buffer |

The handler runs inside your LiveView process, so it does the minimum: a few map
lookups, one struct, a small sanitize pass and two ETS writes. No messages, no
serialization, no I/O, and the socket is never copied.

### Event model

```elixir
%LiveViewVisualizer.Event{
  id: 42,                 # unique per node
  parent_id: nil,         # reserved for future correlation
  trace_id: nil,          # reserved for future correlation
  type: :live_view,       # :live_view | :live_component | ... (open set)
  name: :handle_event,    # operation within the type
  status: :ok,            # :ok | :exception | :error
  module: MyAppWeb.CartLive,
  pid: #PID<0.512.0>,
  source: [:phoenix, :live_view, :handle_event, :stop],
  monotonic_time: ...,    # start, native units, for ordering and offsets
  system_time: ...,       # start, native units, for display only
  duration: ...,          # native units, nil for point-in-time events
  measurements: %{},      # numeric only
  metadata: %{}           # see "Metadata kept" above
}
```

### Safety guarantees

- **Never crashes your app.** Every instrumentation call is wrapped. A failure drops
  that one event, logs once (exception module only, never the message) and the
  handler stays attached. LiveView's own error behaviour is unchanged: a raising
  callback crashes exactly as it would without the visualizer (this is tested).
- **Bounded memory.** At most `max_events` events, each limited in size.
- **No persistence.** Everything lives in ETS. Nothing is written to disk or a database.
- **No sensitive data.** The LiveView instrumentation allowlists fields, and the
  generic sanitizer additionally redacts keys containing `password`, `passwd`,
  `secret`, `token`, `csrf`, `api_key`, `apikey`, `private_key`, `auth`, `cookie`,
  `session` or `credential`, and reduces structs to their module name.

## Compatibility

Verified against the source of, and tested with:

| Phoenix LiveView | Phoenix | Result |
| --- | --- | --- |
| 1.0.19 | 1.7.24 | full suite passes |
| 1.1.28 | 1.8.15 | full suite passes |
| 1.2.12 | 1.8.15 | full suite passes (default) |

`events/0` selects the telemetry events for the installed version, for example
`destroyed` only from 1.1.0.

## Testing

```bash
mix deps.get
mix test
mix format --check-formatted
mix credo --strict
```

The suite includes real Phoenix LiveView integration tests (`Phoenix.LiveViewTest`
against a test endpoint): lifecycle order, components, exceptions, metadata safety,
disabled mode, and a separate VM booted without Phoenix LiveView on the code path.

## Roadmap

- **Phase 1 – Foundation**: config, event model, store, sanitizer, telemetry plumbing.
- **Phase 2 – LiveView lifecycle instrumentation** (this release).
- **Phase 3 – Ecto instrumentation**: queries, and correlating them with the
  LiveView callback that ran them.
- **Phase 4 – Dev dashboard**: a LiveView UI at a development-only route.
- **Later**: `handle_info` / `handle_async`, assigns diffs, processes and tasks, PubSub.

Not planned: production monitoring, persistence or distributed tracing. This is a
development tool.

## License

MIT. See the `LICENSE` file.
