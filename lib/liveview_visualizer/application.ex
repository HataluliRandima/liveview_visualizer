defmodule LiveViewVisualizer.Application do
  @moduledoc """
  OTP application for the visualizer.

  When enabled, the supervision tree is:

      LiveViewVisualizer.Supervisor (one_for_one)
      ├── LiveViewVisualizer.Store       owns the ETS ring buffer
      └── LiveViewVisualizer.Telemetry   owns the :telemetry handler attachments

  The Store starts first so the table exists before any handler can fire. The
  children do not depend on each other at runtime: handlers write to the named
  ETS table directly and tolerate it being briefly missing during a Store
  restart. So `:one_for_one` is enough, and restarting one child never detaches
  or drops anything owned by the other.

  When disabled, the supervisor starts with no children. No ETS table is
  created and no telemetry handler is attached.
  """

  use Application

  alias LiveViewVisualizer.Config

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(Config.enabled?()),
      strategy: :one_for_one,
      name: LiveViewVisualizer.Supervisor
    )
  end

  defp children(true), do: [LiveViewVisualizer.Store, LiveViewVisualizer.Telemetry]
  defp children(false), do: []
end
