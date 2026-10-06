defmodule LiveViewVisualizer.Telemetry do
  @moduledoc """
  Attaches and detaches `:telemetry` handlers for `LiveViewVisualizer.Instrumentation` modules.

  This process owns the handler attachments. It attaches the configured
  instrumentations on start and detaches them when it terminates, so the
  attachments live and die with the visualizer's supervision tree.

  ## Failure isolation

  `:telemetry` runs handlers synchronously in the process that emitted the event,
  which is the host application's own process. The handler installed here
  therefore:

    * catches every error, throw and exit raised by an instrumentation, so the
      host process is never affected;
    * stays attached after a failure. Plain `:telemetry` permanently detaches a
      handler that raises, which would silently turn the visualizer off. Here
      only the failing event is dropped;
    * logs only the first failure per instrumentation, with the exception module
      but not its message, since messages such as `KeyError` can contain
      application data.

  When the visualizer is disabled this process is not started and no handlers are
  attached, so the host application pays no instrumentation cost at all.
  """

  use GenServer

  require Logger

  alias LiveViewVisualizer.{Collector, Config, Sanitizer}

  @doc """
  Starts the handler manager.

  ## Options

    * `:instrumentations` - modules to attach on start. Defaults to
      `LiveViewVisualizer.Config.instrumentations/0`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attaches an instrumentation module's handlers.

  Re-attaching an already attached module replaces its handlers, which also
  picks up changes to its `c:LiveViewVisualizer.Instrumentation.events/0`.
  """
  @spec attach(module()) ::
          :ok | {:error, :not_running | :not_an_instrumentation | :no_events | term()}
  def attach(instrumentation) when is_atom(instrumentation) do
    safe_call({:attach, instrumentation})
  end

  @doc """
  Detaches an instrumentation module's handlers.
  """
  @spec detach(module()) :: :ok | {:error, :not_running | :not_attached}
  def detach(instrumentation) when is_atom(instrumentation) do
    safe_call({:detach, instrumentation})
  end

  @doc """
  Returns the currently attached instrumentation modules.
  """
  @spec attached() :: [module()]
  def attached do
    case safe_call(:attached) do
      {:error, :not_running} -> []
      modules -> modules
    end
  end

  @doc false
  # The :telemetry handler. A public, remote function is required so that
  # :telemetry can call it efficiently and it survives code reloading.
  @spec handle_telemetry_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          map()
        ) :: :ok
  def handle_telemetry_event(event_name, measurements, metadata, config) do
    %{instrumentation: instrumentation, sanitizer: sanitizer} = config

    case instrumentation.handle_event(event_name, measurements, metadata)
         |> Collector.collect(sanitizer) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      {:error, {:invalid_event, _}} -> report_failure(config, event_name, :invalid_return)
    end
  rescue
    exception -> report_failure(config, event_name, {:error, exception.__struct__})
  catch
    kind, _reason -> report_failure(config, event_name, kind)
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 runs on shutdown and handlers are detached.
    Process.flag(:trap_exit, true)

    state = %{
      sanitizer: Sanitizer.new(redact_keys: Config.redact_keys()),
      attached: []
    }

    instrumentations = Keyword.get_lazy(opts, :instrumentations, &Config.instrumentations/0)

    state =
      Enum.reduce(instrumentations, state, fn instrumentation, state ->
        case do_attach(instrumentation, state) do
          {:ok, state} ->
            state

          {:error, :no_events} ->
            # Expected when the instrumented library is not part of the host app.
            Logger.debug(
              "[LiveViewVisualizer] skipping #{inspect(instrumentation)}: no events to attach"
            )

            state

          {:error, reason} ->
            Logger.warning(
              "[LiveViewVisualizer] could not attach instrumentation " <>
                "#{inspect(instrumentation)}: #{inspect(reason)}"
            )

            state
        end
      end)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:attach, instrumentation}, _from, state) do
    case do_attach(instrumentation, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, instrumentation}, _from, state) do
    if instrumentation in state.attached do
      :telemetry.detach(handler_id(instrumentation))
      {:reply, :ok, %{state | attached: List.delete(state.attached, instrumentation)}}
    else
      {:reply, {:error, :not_attached}, state}
    end
  end

  def handle_call(:attached, _from, state) do
    {:reply, Enum.reverse(state.attached), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.attached, &:telemetry.detach(handler_id(&1)))
  end

  defp do_attach(instrumentation, state) do
    with :ok <- validate_instrumentation(instrumentation),
         {:ok, events} <- fetch_events(instrumentation) do
      handler_id = handler_id(instrumentation)

      # Detach first so attaching is idempotent, including after a restart of
      # this process that skipped terminate/2.
      :telemetry.detach(handler_id)

      config = %{
        instrumentation: instrumentation,
        sanitizer: state.sanitizer,
        failures: :atomics.new(1, signed: false)
      }

      case :telemetry.attach_many(
             handler_id,
             events,
             &__MODULE__.handle_telemetry_event/4,
             config
           ) do
        :ok ->
          attached = [instrumentation | List.delete(state.attached, instrumentation)]
          {:ok, %{state | attached: attached}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_instrumentation(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :events, 0),
         true <- function_exported?(module, :handle_event, 3) do
      :ok
    else
      _ -> {:error, :not_an_instrumentation}
    end
  end

  defp fetch_events(module) do
    case module.events() do
      [] ->
        {:error, :no_events}

      events when is_list(events) ->
        if Enum.all?(events, &valid_event_name?/1),
          do: {:ok, events},
          else: {:error, :invalid_events}

      _other ->
        {:error, :invalid_events}
    end
  rescue
    exception -> {:error, {:events_failed, exception.__struct__}}
  end

  defp valid_event_name?(name), do: is_list(name) and name != [] and Enum.all?(name, &is_atom/1)

  defp handler_id(instrumentation), do: {__MODULE__, instrumentation}

  defp report_failure(%{failures: failures, instrumentation: instrumentation}, event_name, reason) do
    if :atomics.add_get(failures, 1, 1) == 1 do
      Logger.warning(
        "[LiveViewVisualizer] instrumentation #{inspect(instrumentation)} failed while handling " <>
          "#{inspect(event_name)} (#{describe(reason)}). The event was dropped and the " <>
          "application was not affected. Further failures from this instrumentation are not logged."
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp describe({:error, exception_module}), do: "raised #{inspect(exception_module)}"

  defp describe(:invalid_return),
    do: "returned something other than an Event, a list of Events or :ignore"

  defp describe(kind), do: "#{kind}"

  defp safe_call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _ -> {:error, :not_running}
  end
end
