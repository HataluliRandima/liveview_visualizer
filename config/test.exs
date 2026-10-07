import Config

config :liveview_visualizer,
  enabled: true,
  max_events: 100

config :logger, level: :warning

config :liveview_visualizer, LiveViewVisualizer.TestApp.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("lvv-test-secret-key-base-", 4),
  live_view: [signing_salt: "lvv-test-live-view-salt"],
  render_errors: [formats: [html: LiveViewVisualizer.TestApp.ErrorHTML], layout: false],
  server: false

config :phoenix, :json_library, Jason

# A dedicated database on a local PostgreSQL server; override with LVV_DATABASE_URL.
database_url =
  System.get_env(
    "LVV_DATABASE_URL",
    "ecto://postgres:postgres@localhost:5432/liveview_visualizer_test"
  )

config :liveview_visualizer, LiveViewVisualizer.TestRepo,
  url: database_url,
  pool_size: 5,
  log: false

config :liveview_visualizer, LiveViewVisualizer.AnalyticsRepo,
  url: database_url,
  pool_size: 2,
  log: false,
  telemetry_prefix: [:analytics, :db]
