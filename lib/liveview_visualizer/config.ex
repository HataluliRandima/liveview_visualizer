defmodule LiveViewVisualizer.Config do
  @moduledoc """
  Centralized access to `:liveview_visualizer` application configuration.

  All configuration is read at runtime from the application environment, so it
  works with values computed in the host application's config files, for example:

      # config/dev.exs
      config :liveview_visualizer, enabled: true

      # or, in a shared config file
      config :liveview_visualizer, enabled: config_env() == :dev

  The library itself never calls `Mix.env/0`, which is not available in releases.

  ## Options

    * `:enabled` - whether the visualizer starts its processes and attaches
      telemetry handlers. Only the literal `true` enables it. Defaults to `false`.

    * `:max_events` - the maximum number of events retained in memory. Older
      events are overwritten once the limit is reached. Defaults to `1000`.

    * `:redact_keys` - additional metadata keys (atoms or strings) whose values
      are always replaced with `:redacted`. They are matched case-insensitively
      as substrings, in addition to the built-in list in
      `LiveViewVisualizer.Sanitizer`. Defaults to `[]`.

    * `:instrumentations` - modules implementing `LiveViewVisualizer.Instrumentation`
      to attach on startup. Defaults to `[]`. This is an extension point. Phase 1
      ships no built-in instrumentation.

  Most options are read once when the application starts. Changing them at runtime
  requires restarting the `:liveview_visualizer` application.

  Invalid values never prevent the host application from booting. A warning is
  logged and the default is used instead.
  """

  require Logger

  @app :liveview_visualizer

  @default_max_events 1_000

  @doc """
  Returns `true` only when `config :liveview_visualizer, enabled: true` is set.

  Any other value, including a missing key, `"true"` or `1`, means disabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(@app, :enabled, false) === true
  end

  @doc """
  Returns the maximum number of events the store keeps.
  """
  @spec max_events() :: pos_integer()
  def max_events do
    case Application.get_env(@app, :max_events, @default_max_events) do
      value when is_integer(value) and value > 0 ->
        value

      invalid ->
        warn_invalid(:max_events, invalid, "a positive integer", @default_max_events)
        @default_max_events
    end
  end

  @doc """
  Returns the user-configured keys to redact from event metadata.
  """
  @spec redact_keys() :: [atom() | String.t()]
  def redact_keys do
    case Application.get_env(@app, :redact_keys, []) do
      keys when is_list(keys) ->
        if Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) do
          keys
        else
          warn_invalid(:redact_keys, keys, "a list of atoms or strings", [])
          []
        end

      invalid ->
        warn_invalid(:redact_keys, invalid, "a list of atoms or strings", [])
        []
    end
  end

  @doc """
  Returns the instrumentation modules to attach on startup.
  """
  @spec instrumentations() :: [module()]
  def instrumentations do
    case Application.get_env(@app, :instrumentations, []) do
      modules when is_list(modules) ->
        if Enum.all?(modules, &is_atom/1) do
          modules
        else
          warn_invalid(:instrumentations, modules, "a list of modules", [])
          []
        end

      invalid ->
        warn_invalid(:instrumentations, invalid, "a list of modules", [])
        []
    end
  end

  defp warn_invalid(key, value, expected, default) do
    Logger.warning(
      "[LiveViewVisualizer] invalid value for config :liveview_visualizer, #{inspect(key)}: " <>
        "expected #{expected}, got: #{inspect(value, limit: 5)}. Using #{inspect(default)}."
    )
  end
end
