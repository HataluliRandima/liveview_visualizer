defmodule LiveViewVisualizer.Trace do
  @moduledoc """
  Turns a window of stored events into what the dashboard displays.

  Pure functions over `LiveViewVisualizer.Event` structs, with no processes and
  no state. Everything is derived from the events themselves. There is no
  second event representation and no separate metrics store.

  ## Trees

  Trees are built **only** from `parent_id`. An event whose `parent_id` is `nil`
  is a root. An event whose parent is no longer in the window (it was evicted
  from the ring buffer) is also shown as a root, marked `orphan?: true`. No
  relationship is ever inferred from timing, order, process or socket. For
  example, the `render` that follows a `handle_event` is a separate root,
  because LiveView does not run it inside the `handle_event`.

  ## Groups

  Roots are grouped for display. Grouping never changes the trees:

    * **LiveView instance** - roots with the same `socket_id`. A socket id
      identifies one LiveView on one page across its disconnected (HTTP) render
      and its connected process, and across reconnects. A group can therefore
      contain several pids, which are listed. LiveComponent events carry their
      LiveView's socket id and appear in that LiveView's group.
    * **Outside LiveView callbacks** - every other root, such as queries from
      Tasks, background jobs or `handle_info`. These are deliberately not
      attributed to any LiveView.

  Groups are ordered by most recent activity. Roots inside a group, and the
  children of each event, are ordered by start time. A root whose pid differs
  from the previous root's is marked `new_process?: true`. This shows where
  the disconnected render ends, where the connected process begins, and where a
  crashed LiveView was rejoined in a new process.

  ## Filters

  `type`, `status` and the free-text `query` match individual events. A tree is
  shown if any of its events matches, and the non-matching events stay visible
  as context (`match?: false`). `view` selects LiveView groups by module.
  """

  alias LiveViewVisualizer.Event

  defmodule Filters do
    @moduledoc ~s(Dashboard filter criteria. `nil` and `""` mean "any".)

    @type t :: %__MODULE__{
            view: module() | nil,
            type: atom() | nil,
            status: Event.status() | nil,
            query: String.t()
          }

    defstruct view: nil, type: nil, status: nil, query: ""

    @doc "Whether any filter is set."
    @spec active?(t()) :: boolean()
    def active?(%__MODULE__{} = f),
      do: f.view != nil or f.type != nil or f.status != nil or f.query != ""
  end

  @type tree :: %{
          event: Event.t(),
          children: [tree()],
          match?: boolean(),
          orphan?: boolean(),
          new_process?: boolean()
        }

  @type group :: %{
          key: {:live_view, String.t()} | :other,
          view: module() | nil,
          socket_id: String.t() | nil,
          pids: [pid()],
          roots: [tree()],
          hidden_roots: non_neg_integer(),
          last_activity: integer()
        }

  @type stats :: %{
          live_views: non_neg_integer(),
          events: non_neg_integer(),
          queries: non_neg_integer(),
          errors: non_neg_integer()
        }

  @type live_view_summary :: %{
          view: module(),
          events: non_neg_integer(),
          queries: non_neg_integer(),
          errors: non_neg_integer()
        }

  @type t :: %{
          stats: stats(),
          live_views: [live_view_summary()],
          groups: [group()],
          index: %{Event.id() => Event.t()},
          child_counts: %{Event.id() => non_neg_integer()},
          max_duration: pos_integer()
        }

  @live_types [:live_view, :live_component]
  @max_depth 32

  @doc """
  Builds the full view model for `events`.

  ## Options

    * `:max_roots` - per group, only the most recent roots are kept (default `100`).
      The number left out is reported as `hidden_roots`.

  """
  @spec build([Event.t()], Filters.t(), keyword()) :: t()
  def build(events, %Filters{} = filters \\ %Filters{}, opts \\ []) do
    max_roots = Keyword.get(opts, :max_roots, 100)
    index = Map.new(events, &{&1.id, &1})
    children = children_by_parent(events, index)

    %{
      stats: stats(events),
      live_views: live_views(events, index),
      groups: groups(events, index, children, filters, max_roots),
      index: index,
      child_counts: Map.new(children, fn {id, kids} -> {id, length(kids)} end),
      max_duration: max_duration(events)
    }
  end

  @doc """
  Whether `event` matches the event-level filters (`type`, `status`, `query`).
  """
  @spec matches?(Event.t(), Filters.t()) :: boolean()
  def matches?(%Event{} = event, %Filters{} = filters) do
    (filters.type == nil or event.type == filters.type) and
      (filters.status == nil or event.status == filters.status) and
      (filters.query == "" or String.contains?(search_text(event), String.downcase(filters.query)))
  end

  @doc """
  The LiveView module an event belongs to: its own `view`, or for an event
  without one (such as a query), its parent's. Never guessed beyond `parent_id`.
  """
  @spec view_of(Event.t(), %{Event.id() => Event.t()}) :: module() | nil
  def view_of(%Event{metadata: %{view: view}}, _index) when is_atom(view) and not is_nil(view),
    do: view

  def view_of(%Event{parent_id: nil}, _index), do: nil

  def view_of(%Event{parent_id: parent_id}, index) do
    case index do
      %{^parent_id => parent} -> view_of(parent, index)
      _ -> nil
    end
  end

  ## Stats

  defp stats(events) do
    %{
      live_views: events |> Enum.flat_map(&own_view/1) |> Enum.uniq() |> length(),
      events: length(events),
      queries: Enum.count(events, &(&1.type == :ecto)),
      errors: Enum.count(events, &(&1.status != :ok))
    }
  end

  defp live_views(events, index) do
    events
    |> Enum.group_by(&view_of(&1, index))
    |> Enum.reject(fn {view, _} -> is_nil(view) end)
    |> Enum.map(fn {view, events} ->
      %{
        view: view,
        events: length(events),
        queries: Enum.count(events, &(&1.type == :ecto)),
        errors: Enum.count(events, &(&1.status != :ok))
      }
    end)
    |> Enum.sort_by(&{-&1.events, inspect(&1.view)})
  end

  defp own_view(%Event{type: type, metadata: %{view: view}})
       when type in @live_types and is_atom(view) and not is_nil(view),
       do: [view]

  defp own_view(_event), do: []

  defp max_duration(events) do
    events |> Enum.map(&(&1.duration || 0)) |> Enum.max(fn -> 0 end) |> max(1)
  end

  ## Trees and groups

  defp children_by_parent(events, index) do
    events
    |> Enum.filter(&(&1.parent_id != nil and Map.has_key?(index, &1.parent_id)))
    |> Enum.group_by(& &1.parent_id)
    |> Map.new(fn {id, kids} -> {id, Enum.sort_by(kids, &{&1.monotonic_time, &1.id})} end)
  end

  defp groups(events, index, children, filters, max_roots) do
    events
    |> Enum.filter(&(&1.parent_id == nil or not Map.has_key?(index, &1.parent_id)))
    |> Enum.sort_by(&{&1.monotonic_time, &1.id})
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {key, roots} -> group(key, roots, children, filters, max_roots) end)
    |> Enum.filter(&group_visible?(&1, filters))
    |> Enum.sort_by(& &1.last_activity, :desc)
  end

  defp group_key(%Event{metadata: %{socket_id: socket_id}}) when is_binary(socket_id),
    do: {:live_view, socket_id}

  defp group_key(_event), do: :other

  defp group(key, roots, children, filters, max_roots) do
    trees = roots |> Enum.map(&tree(&1, children, filters, 0)) |> mark_process_changes()
    all_events = Enum.flat_map(trees, &flatten/1)
    visible = Enum.filter(trees, &tree_visible?(&1, filters))
    hidden = max(length(visible) - max_roots, 0)

    %{
      key: key,
      view: if(key == :other, do: nil, else: roots |> Enum.find_value(&own_view_value/1)),
      socket_id: socket_id(key),
      pids: all_events |> Enum.map(& &1.pid) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      roots: Enum.drop(visible, hidden),
      hidden_roots: hidden,
      last_activity: all_events |> Enum.map(&finish_time/1) |> Enum.max(fn -> 0 end)
    }
  end

  defp socket_id({:live_view, socket_id}), do: socket_id
  defp socket_id(:other), do: nil

  defp own_view_value(event) do
    case own_view(event) do
      [view] -> view
      [] -> nil
    end
  end

  defp tree(event, children, filters, depth) do
    kids =
      if depth < @max_depth,
        do: Enum.map(Map.get(children, event.id, []), &tree(&1, children, filters, depth + 1)),
        else: []

    %{
      event: event,
      children: kids,
      match?: matches?(event, filters),
      orphan?: event.parent_id != nil and depth == 0,
      new_process?: false
    }
  end

  defp mark_process_changes(trees) do
    {marked, _last_pid} =
      Enum.map_reduce(trees, :none, fn tree, last_pid ->
        {%{tree | new_process?: tree.event.pid != last_pid}, tree.event.pid}
      end)

    marked
  end

  defp flatten(%{event: event, children: children}),
    do: [event | Enum.flat_map(children, &flatten/1)]

  defp tree_visible?(%{match?: true}, _filters), do: true

  defp tree_visible?(%{children: children}, filters),
    do: Enum.any?(children, &tree_visible?(&1, filters))

  defp group_visible?(%{roots: []}, _filters), do: false
  defp group_visible?(_group, %Filters{view: nil}), do: true
  defp group_visible?(%{view: view}, %Filters{view: view}), do: true
  defp group_visible?(_group, _filters), do: false

  defp finish_time(%Event{monotonic_time: start, duration: duration}), do: start + (duration || 0)

  ## Search

  # Only safe, displayed fields are searchable.
  @searchable [
    :event,
    :source,
    :repo,
    :view,
    :component,
    :route,
    :command,
    :exception,
    :error_code
  ]

  defp search_text(%Event{} = event) do
    fields =
      [event.type, event.name, event.module, event.status] ++
        Enum.map(@searchable, &Map.get(event.metadata, &1))

    fields
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &searchable/1)
    |> String.downcase()
  end

  defp searchable(value) when is_binary(value), do: value
  defp searchable(value) when is_atom(value), do: value |> inspect() |> String.trim_leading(":")
  defp searchable(value), do: inspect(value)
end
