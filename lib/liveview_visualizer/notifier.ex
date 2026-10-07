defmodule LiveViewVisualizer.Notifier do
  @moduledoc """
  Lightweight change notifications for readers of the store, such as the dashboard.

  Notifications go through a `Phoenix.PubSub` server owned by the visualizer
  (`LiveViewVisualizer.PubSub`), never through the host application's PubSub. They
  are always broadcast locally, never to other nodes. Messages carry only an
  event id, never the event, so they stay small:

    * `{:event_recorded, event_id}` - an event was stored
    * `:events_cleared` - the store was cleared

  Subscribers then read what they need from `LiveViewVisualizer.Store`.

  The PubSub server is started only when the visualizer is enabled and
  `:phoenix_pubsub` is available. Otherwise notifying is a cheap no-op.
  Notifying runs in the process that recorded the event, so it never raises.
  """

  # Phoenix.PubSub is only present when the host application uses Phoenix.
  @compile {:no_warn_undefined, Phoenix.PubSub}

  @pubsub LiveViewVisualizer.PubSub
  @topic "liveview_visualizer:events"

  @doc """
  The child spec for the visualizer's PubSub server, or `nil` if
  `Phoenix.PubSub` is not available.
  """
  @spec child_spec_if_available() :: Supervisor.child_spec() | nil
  def child_spec_if_available do
    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Supervisor.child_spec({Phoenix.PubSub, name: @pubsub}, id: @pubsub)
  end

  @doc """
  Subscribes the calling process to notifications.

  Returns `{:error, :not_running}` if notifications are unavailable.
  """
  @spec subscribe() :: :ok | {:error, :not_running}
  def subscribe do
    if running?(), do: Phoenix.PubSub.subscribe(@pubsub, @topic), else: {:error, :not_running}
  end

  @doc "Announces that the event with `event_id` was stored."
  @spec event_recorded(LiveViewVisualizer.Event.id()) :: :ok
  def event_recorded(event_id), do: broadcast({:event_recorded, event_id})

  @doc "Announces that the store was cleared."
  @spec events_cleared() :: :ok
  def events_cleared, do: broadcast(:events_cleared)

  defp broadcast(message) do
    if running?(), do: Phoenix.PubSub.local_broadcast(@pubsub, @topic, message)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp running?, do: Process.whereis(@pubsub) != nil
end
