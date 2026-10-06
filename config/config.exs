import Config

# This configuration only applies when developing the library itself.
# Applications that depend on :liveview_visualizer configure it in their own
# config files; see the README.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
