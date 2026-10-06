defmodule LiveViewVisualizer.WithoutLiveViewTest do
  # Boots a separate VM whose code path contains only this library and
  # :telemetry, which is what a host application without Phoenix LiveView has.
  use ExUnit.Case, async: true

  @moduletag timeout: 120_000

  @script ~S"""
  Application.put_env(:liveview_visualizer, :enabled, true)
  {:ok, _} = Application.ensure_all_started(:liveview_visualizer)

  alias LiveViewVisualizer.{Collector, Event, Telemetry}
  alias LiveViewVisualizer.Instrumentation.LiveView

  checks = [
    live_view_absent: not Code.ensure_loaded?(Phoenix.LiveView),
    no_version: LiveView.live_view_version() == nil,
    no_events: LiveView.events() == [],
    nothing_attached: Telemetry.attached() == [],
    store_works: Collector.collect(Event.new!(type: :custom, name: :ping)) == :ok,
    retrievable: match?([%Event{name: :ping}], LiveViewVisualizer.recent_events()),
    telemetry_safe: :telemetry.execute([:phoenix, :live_view, :mount, :stop], %{duration: 1}, %{}) == :ok
  ]

  IO.inspect(checks, label: "CHECKS")
  """

  test "the application starts and works without Phoenix LiveView installed" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    code_path =
      for app <- [:liveview_visualizer, :telemetry] do
        ["-pa", app |> :code.lib_dir() |> Path.join("ebin")]
      end

    {output, status} =
      System.cmd(elixir, List.flatten(code_path) ++ ["-e", @script], stderr_to_stdout: true)

    assert status == 0, output
    assert [_, checks] = Regex.run(~r/CHECKS: (\[.*\])/s, output), output
    {checks, _} = Code.eval_string(checks)

    for {check, result} <- checks, do: assert(result, "check #{check} failed:\n#{output}")
    assert length(checks) == 7
  end
end
