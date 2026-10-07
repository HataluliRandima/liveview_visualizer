defmodule LiveViewVisualizer do
  @moduledoc """
  Development-time observability for Phoenix LiveView.

  When enabled with `config :liveview_visualizer, enabled: true`, LiveView and
  LiveComponent lifecycle events (`LiveViewVisualizer.Instrumentation.LiveView`)
  and Ecto queries (`LiveViewVisualizer.Instrumentation.Ecto`) are recorded
  automatically. Queries run inside a LiveView callback are linked to it
  (`LiveViewVisualizer.Context`). Inspect them with `recent_events/1`. No changes
  to LiveViews, contexts, schemas or repos are needed.

  The building blocks are:

    * `LiveViewVisualizer.Config` - centralized, safe-by-default configuration
    * `LiveViewVisualizer.Event` - the normalized event representation
    * `LiveViewVisualizer.Store` - a bounded, in-memory ETS ring buffer
    * `LiveViewVisualizer.Collector` - sanitizes events and records them
    * `LiveViewVisualizer.Telemetry` - failure-isolated `:telemetry` handler management
    * `LiveViewVisualizer.Instrumentation` - the behaviour that event sources implement

  Process and PubSub instrumentation and the dashboard are not implemented
  yet. See the README for the roadmap.
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
