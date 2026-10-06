defmodule LiveViewVisualizer do
  @moduledoc """
  Development-time observability for Phoenix LiveView.

  This is the foundation release (Phase 1). It provides:

    * `LiveViewVisualizer.Config` - centralized, safe-by-default configuration
    * `LiveViewVisualizer.Event` - the normalized event representation
    * `LiveViewVisualizer.Store` - a bounded, in-memory ETS ring buffer
    * `LiveViewVisualizer.Collector` - sanitizes events and records them
    * `LiveViewVisualizer.Telemetry` - failure-isolated `:telemetry` handler management
    * `LiveViewVisualizer.Instrumentation` - the behaviour that event sources implement

  No LiveView, Ecto, process or PubSub instrumentation ships yet. See the README
  for the roadmap.
  """

  alias LiveViewVisualizer.{Config, Event, Store}

  @doc """
  Returns whether the visualizer is enabled in configuration.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: Config

  @doc """
  Returns up to `limit` of the most recent events, oldest first.

  See `LiveViewVisualizer.Store.recent/1`.
  """
  @spec recent_events(pos_integer() | nil) :: [Event.t()]
  def recent_events(limit \\ nil), do: Store.recent(limit)

  @doc """
  Removes all stored events.
  """
  @spec clear_events() :: :ok
  defdelegate clear_events, to: Store, as: :clear
end
