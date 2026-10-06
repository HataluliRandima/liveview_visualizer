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
