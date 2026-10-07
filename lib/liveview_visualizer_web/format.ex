defmodule LiveViewVisualizerWeb.Format do
  @moduledoc """
  Presentation helpers for the dashboard: labels, durations and event details.

  `details/3` is the single place that decides which fields the dashboard
  shows. It reads an explicit allowlist of the fields the built-in
  instrumentations store. Any other metadata key, including keys added by
  custom instrumentations, is never rendered.
  """

  alias LiveViewVisualizer.Event

  @doc """
  The one-line label of an event in the trace view.

  ## Examples

      iex> event = LiveViewVisualizer.Event.new!(type: :live_view, name: :handle_event, metadata: %{event: "search"})
      iex> LiveViewVisualizerWeb.Format.label(event)
      ~s{handle_event("search")}

  """
  @spec label(Event.t()) :: String.t()
  def label(%Event{type: :ecto, metadata: metadata}) do
    case metadata[:source] do
      source when is_binary(source) -> "Ecto query · " <> source
      _ -> "Ecto query"
    end
  end

  def label(%Event{type: :live_component, name: name, module: module, metadata: metadata}) do
    "#{call(name, metadata[:event])} · #{short_module(module)}"
  end

  def label(%Event{name: :mount, metadata: %{connected?: true}}), do: "mount (connected)"
  def label(%Event{name: :mount, metadata: %{connected?: false}}), do: "mount (disconnected)"
  def label(%Event{name: name, metadata: metadata}), do: call(name, metadata[:event])

  defp call(name, event) when is_binary(event), do: ~s{#{name}("#{event}")}
  defp call(name, _event), do: to_string(name)

  @doc """
  A module name without its namespace, e.g. `InventoryLive`.

  ## Examples

      iex> LiveViewVisualizerWeb.Format.short_module(MyAppWeb.InventoryLive)
      "InventoryLive"

  """
  @spec short_module(module() | nil) :: String.t()
  def short_module(nil), do: "-"

  def short_module(module) when is_atom(module),
    do: module |> inspect() |> String.split(".") |> List.last()

  @doc """
  Formats a native-unit duration for display.

  ## Examples

      iex> LiveViewVisualizerWeb.Format.duration(System.convert_time_unit(51_100, :microsecond, :native))
      "51.1ms"

      iex> LiveViewVisualizerWeb.Format.duration(System.convert_time_unit(850, :microsecond, :native))
      "850µs"

  """
  @spec duration(integer() | nil) :: String.t()
  def duration(nil), do: "-"

  def duration(native) do
    us = System.convert_time_unit(native, :native, :microsecond)

    cond do
      us < 1_000 -> "#{us}µs"
      us < 1_000_000 -> "#{decimals(us / 1_000)}ms"
      true -> "#{decimals(us / 1_000_000)}s"
    end
  end

  defp decimals(value) when value >= 100, do: :erlang.float_to_binary(value, decimals: 0)
  defp decimals(value) when value >= 10, do: :erlang.float_to_binary(value, decimals: 1)
  defp decimals(value), do: :erlang.float_to_binary(value, decimals: 2)

  @doc "Bar width for a duration, as a percentage of `max_duration`."
  @spec bar_width(integer() | nil, pos_integer()) :: float()
  def bar_width(duration, max_duration) when is_integer(duration) and duration > 0,
    do: Float.round(max(duration / max_duration * 100, 0.5), 2)

  def bar_width(_duration, _max_duration), do: 0.0

  @doc "A short display name for an event type."
  @spec type_name(atom()) :: String.t()
  def type_name(:live_view), do: "LiveView"
  def type_name(:live_component), do: "LiveComponent"
  def type_name(:ecto), do: "Ecto"
  def type_name(type), do: type |> to_string() |> String.capitalize()

  @doc "A short display name for a status."
  @spec status_name(Event.status()) :: String.t()
  def status_name(:ok), do: "OK"
  def status_name(:error), do: "ERROR"
  def status_name(:exception), do: "EXCEPTION"

  @doc """
  The rows of the event detail panel, as `{label, value}` pairs.

  Only allowlisted, already-sanitized fields are included. `index` and
  `child_counts` (from `LiveViewVisualizer.Trace.build/3`) resolve the parent's
  label and the number of children.
  """
  @spec details(Event.t(), map(), map()) :: [{String.t(), String.t()}]
  def details(%Event{} = event, index, child_counts) do
    meta = event.metadata

    [
      {"Type", type_name(event.type)},
      {"Operation", to_string(event.name)},
      {"Event", meta[:event]},
      {"Module", module_name(event.module)},
      {"View", module_name(meta[:view])},
      {"Component", module_name(meta[:component])},
      {"CID", meta[:cid]},
      {"Repo", module_name(meta[:repo])},
      {"Source", if(event.type == :ecto, do: meta[:source] || "-")},
      {"Command", meta[:command]},
      {"Rows", meta[:num_rows]},
      {"Route", meta[:route]},
      {"Connected", meta[:connected?]},
      {"Changed", meta[:changed?]},
      {"Components updated", meta[:count]},
      {"Status", status_name(event.status)},
      {"Exception", module_name(meta[:exception])},
      {"Kind", meta[:kind]},
      {"Error code", meta[:error_code]},
      {"Duration", duration(event.duration)},
      {"Query time", measurement(event, :query_time)},
      {"Queue time", measurement(event, :queue_time)},
      {"Decode time", measurement(event, :decode_time)},
      {"Started", timestamp(event, 0)},
      {"Finished", if(event.duration, do: timestamp(event, event.duration))},
      {"PID", pid(event.pid)},
      {"Socket", meta[:socket_id]},
      {"Parent", parent(event, index)},
      {"Children", Map.get(child_counts, event.id, 0)},
      {"Trace", event.trace_id},
      {"Event id", event.id}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map(fn {label, value} -> {label, text(value)} end)
  end

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_other), do: nil

  defp measurement(%Event{measurements: measurements}, key) do
    case measurements do
      %{^key => value} when is_integer(value) -> duration(value)
      _ -> nil
    end
  end

  defp timestamp(%Event{} = event, offset) do
    event
    |> Map.update!(:system_time, &(&1 + offset))
    |> Event.started_at()
    |> DateTime.truncate(:millisecond)
    |> Calendar.strftime("%H:%M:%S.%f UTC")
  end

  defp pid(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
  defp pid(_pid), do: nil

  defp parent(%Event{parent_id: nil}, _index), do: "none"

  defp parent(%Event{parent_id: id}, index) do
    case index do
      %{^id => parent} -> "#{label(parent)} · #{short_module(parent.module)} (##{id})"
      _ -> "##{id} (no longer in the buffer)"
    end
  end

  defp text(true), do: "yes"
  defp text(false), do: "no"
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(value), do: inspect(value)
end
