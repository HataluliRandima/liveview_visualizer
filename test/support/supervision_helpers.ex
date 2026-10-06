defmodule LiveViewVisualizer.SupervisionHelpers do
  @moduledoc false
  # Helpers for tests that stop parts of the running visualizer. Each helper
  # registers an on_exit callback that restores the tree for the next test.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @supervisor LiveViewVisualizer.Supervisor

  @doc "Stops a child of the visualizer supervisor for the rest of the test."
  def stop_child(child) do
    :ok = Supervisor.terminate_child(@supervisor, child)
    on_exit(fn -> restart_child(child) end)
    :ok
  end

  @doc "Restarts a child that was terminated (no-op if it is already running)."
  def restart_child(child) do
    case Supervisor.restart_child(@supervisor, child) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  @doc "Waits until `name` is registered to a process other than `old_pid`."
  def await_restart(name, old_pid, attempts \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_restart(name, old_pid, attempts - 1)

      _ ->
        raise "#{inspect(name)} was not restarted"
    end
  end
end
