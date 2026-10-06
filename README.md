# LiveView Lifecycle Visualizer

A developer observability and visualization tool for Phoenix LiveView applications.

> **Status: Phase 1 (foundation).** This release contains the core architecture:
> configuration, a normalized event model, a bounded in-memory event store, metadata
> sanitization and failure-isolated telemetry plumbing. It does **not** yet capture
> LiveView, Ecto, process or PubSub activity, and there is no dashboard yet. See the
> [roadmap](#roadmap).

## What is LiveView Lifecycle Visualizer?

The goal is something like browser DevTools, built for Phoenix LiveView. Add the
library, enable it in development, and see what your LiveViews are doing:

- lifecycle callbacks (`mount`, `handle_params`, `handle_event`, `handle_info`, `render`)
- assigns and state changes
- Ecto queries triggered by those callbacks
- processes, tasks and PubSub messages
- how long each step takes, and how they relate to each other

Instrumentation will be automatic, built on `:telemetry`. You will **never** need
to add tracking calls to your LiveView modules.

## Intended developer experience

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
mix phx.server
```

Once the dashboard ships (a later phase), it will be served at a development-only
route such as `/dev/liveview`.

## Installation

The package is not yet published to Hex. Until it is, depend on it by path or git:

```elixir
def deps do
  [
    {:liveview_visualizer, path: "../liveview_visualizer", only: :dev}
  ]
end
```

Use `only: :dev` so the library is never compiled into test or production builds.

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

  # Instrumentation modules to attach (extension point). Default: [].
  instrumentations: []
```

Computed values work as expected, for example from a shared config file:

```elixir
config :liveview_visualizer, enabled: config_env() == :dev
```

Options are read when the application starts. Changing them requires restarting
the `:liveview_visualizer` application. Invalid values never stop your app from
booting: a warning is logged and the default is used.

### What "disabled" means

With `enabled: false` (the default), the application starts an empty supervisor and
nothing else. No ETS table is created, no telemetry handler is attached, and no
code runs in your application's processes.

## Development usage (Phase 1)

Phase 1 ships no built-in instrumentation, so out of the box the store stays empty.
You can inspect the store and plug in your own `:telemetry` events through the
`LiveViewVisualizer.Instrumentation` behaviour:

```elixir
defmodule MyApp.CheckoutInstrumentation do
  @behaviour LiveViewVisualizer.Instrumentation

  alias LiveViewVisualizer.Event

  @impl true
  def events, do: [[:my_app, :checkout, :stop]]

  @impl true
  def handle_event(source, %{duration: duration}, metadata) do
    case Event.new(
           type: :my_app,
           name: :checkout,
           source: source,
           duration: duration,
           monotonic_time: System.monotonic_time() - duration,
           system_time: System.system_time() - duration,
           metadata: Map.take(metadata, [:order_id])
         ) do
      {:ok, event} -> event
      {:error, _} -> :ignore
    end
  end
end
```

```elixir
# config/dev.exs
config :liveview_visualizer,
  enabled: true,
  instrumentations: [MyApp.CheckoutInstrumentation]
```

```elixir
iex> LiveViewVisualizer.recent_events(10)
[%LiveViewVisualizer.Event{type: :my_app, name: :checkout, duration: 1234567, ...}]

iex> LiveViewVisualizer.clear_events()
:ok
```

## Architecture

```text
LiveViewVisualizer.Application
└── LiveViewVisualizer.Supervisor (one_for_one, empty when disabled)
    ├── LiveViewVisualizer.Store       owns the ETS ring buffer
    └── LiveViewVisualizer.Telemetry   owns :telemetry handler attachments

:telemetry event (in the emitting process, e.g. a LiveView)
  └─> Telemetry handler            (catches every error/throw/exit)
        └─> Instrumentation.handle_event/3   telemetry event -> %Event{}
              └─> Collector.collect/2        sanitize metadata & measurements
                    └─> Store.record/1       2 lock-free ETS writes
```

| Module | Responsibility |
| --- | --- |
| `LiveViewVisualizer.Config` | Reads and validates configuration, safe defaults |
| `LiveViewVisualizer.Event` | The normalized event struct shared by every source |
| `LiveViewVisualizer.Instrumentation` | Behaviour: which telemetry events to attach and how to normalize them |
| `LiveViewVisualizer.Telemetry` | Attaches and detaches handlers, isolates failures |
| `LiveViewVisualizer.Collector` | Single path into the store, always sanitizes |
| `LiveViewVisualizer.Sanitizer` | Redaction and size limits for arbitrary terms |
| `LiveViewVisualizer.Store` | Bounded, concurrent, in-memory ring buffer |

### Event model

```elixir
%LiveViewVisualizer.Event{
  id: 42,                 # unique per node, also the span id
  parent_id: 41,          # enclosing operation, e.g. the handle_event of a query
  trace_id: 40,           # root operation, e.g. one user interaction
  type: :live_view,       # source category (open set of atoms)
  name: :handle_event,    # operation within the category
  status: :ok,            # :ok | :error
  module: MyAppWeb.CartLive,
  pid: #PID<0.512.0>,
  source: [:phoenix, :live_view, :handle_event, :stop],
  monotonic_time: ...,    # start, native units, for ordering and offsets
  system_time: ...,       # start, native units, for display only
  duration: ...,          # native units, nil for instantaneous events
  measurements: %{},      # numeric only
  metadata: %{}           # always sanitized
}
```

`parent_id` and `trace_id` are what will let later phases draw
"LiveView event → DB query / process / PubSub / render" trees. Phase 1 defines
them but does not populate them yet.

### Safety guarantees

- **Never crashes your app.** Handlers run inside your processes, so every
  instrumentation call is wrapped. A failing instrumentation drops that one event,
  logs once (exception module only, never the message) and stays attached. The
  visualizer's own processes are supervised separately from your application.
- **Bounded memory.** The store keeps at most `max_events` events, and the
  sanitizer limits how large each event can be.
- **No persistence.** Everything lives in ETS. Nothing is written to disk or a database.
- **No sensitive data by default.** Keys containing `password`, `passwd`, `secret`,
  `token`, `csrf`, `api_key`, `apikey`, `private_key`, `auth`, `cookie`, `session`
  or `credential` are redacted. Structs (users, changesets, sockets) are reduced
  to their module name. Closures are replaced so captured data is not retained.

## Testing

```bash
mix deps.get
mix test
mix format --check-formatted
mix credo --strict
```

The suite covers configuration (enabled and disabled), the event struct, the
sanitizer, the store (ordering, limits, concurrent writers and readers, crash
recovery), telemetry handling and failure isolation, and the supervision tree in
both the enabled and disabled states.

## Compatibility notes

The lifecycle instrumentation planned for Phase 2 will rely on these telemetry
spans. They were verified in the source of `phoenix_live_view` 1.0.19 and 1.2.12
and are identical in both:

| Event prefix (`:start` / `:stop` / `:exception`) | Notes |
| --- | --- |
| `[:phoenix, :live_view, :mount]` | metadata: `socket`, `params`, `session`, `uri` |
| `[:phoenix, :live_view, :handle_params]` | metadata: `socket`, `params`, `uri` |
| `[:phoenix, :live_view, :handle_event]` | metadata: `socket`, `event`, `params` |
| `[:phoenix, :live_view, :render]` | metadata: `socket`, `force?`, `changed?` |
| `[:phoenix, :live_component, :handle_event]` | metadata: `socket`, `component`, `event`, `params` |
| `[:phoenix, :live_component, :update]` | |
| `[:phoenix, :live_component, :destroyed]` | single event, 1.2 only |

LiveView emits **no** telemetry for `handle_info`, `handle_async` or assign changes.
Capturing those will need a different, still opt-in-free mechanism, to be designed
in a later phase. Version differences will be handled inside each instrumentation's
`events/0`.

## Roadmap

- **Phase 1 – Foundation** (this release): config, event model, store, sanitizer,
  telemetry plumbing, tests.
- **Phase 2 – LiveView lifecycle instrumentation**: `mount`, `handle_params`,
  `handle_event`, `render` and LiveComponent spans, with span correlation.
- **Phase 3 – Ecto instrumentation**: queries linked to the LiveView callback that
  triggered them.
- **Phase 4 – Dev dashboard**: a LiveView UI at a development-only route.
- **Later**: `handle_info`, assigns diffs, processes and tasks, PubSub.

Not planned: production monitoring, persistence or distributed tracing. This is a
development tool.

## License

MIT. See the `LICENSE` file.
