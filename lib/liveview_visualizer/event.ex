defmodule LiveViewVisualizer.Event do
  @moduledoc """
  The normalized representation of a single observed operation.

  Every instrumentation source (LiveView, Ecto, PubSub, processes, ...) converts
  what it observes into this struct before it reaches the store. That keeps the
  store, and any future UI, independent of the libraries being observed.

  ## Fields

    * `:id` - unique (per node) positive integer identifying this event. For
      span-like operations it also acts as the span id, so other events can
      point at it through `:parent_id`.
    * `:parent_id` - the `:id` of the enclosing operation, if known. For example
      an Ecto query executed during a `handle_event` would point at the
      `handle_event` event.
    * `:trace_id` - groups every event caused by the same root operation, such as
      one user interaction. Usually the `:id` of the root event.
    * `:type` - the event category, for example `:live_view`, `:live_component`,
      `:ecto`, `:pubsub` or `:process`. It is an open set of atoms so new sources
      can be added without changing this module.
    * `:name` - the operation within the category, for example `:mount`,
      `:handle_event` or `:query`.
    * `:status` - the outcome of the operation:
      * `:ok` - it completed normally
      * `:exception` - it raised, threw or exited. This corresponds to a
        `:telemetry` span `:exception` event.
      * `:error` - it completed but reported a failure, for example a query
        that returned an error tuple. Reserved for future instrumentations.
    * `:module` - the module the operation belongs to, such as the LiveView module.
    * `:pid` - the process that performed the operation.
    * `:source` - the raw `:telemetry` event name this event was built from, if any.
    * `:monotonic_time` - when the operation started, in `:native` time units, from
      `System.monotonic_time/0`. Use it for ordering and for computing offsets
      between events on the same node.
    * `:system_time` - when the operation started, in `:native` time units, from
      `System.system_time/0`. Use it only for display. It is not monotonic.
    * `:duration` - how long the operation took, in `:native` time units, or `nil`
      for instantaneous events.
    * `:measurements` - additional numeric measurements, for example a query's
      `:queue_time`.
    * `:metadata` - additional context. It is always passed through
      `LiveViewVisualizer.Sanitizer` before it is stored.

  Time values stay in `:native` units so no precision is lost. Use
  `duration/2` and `started_at/1` to convert them.
  """

  @typedoc "Unique event identifier, see `new_id/0`."
  @type id :: pos_integer()

  @type status :: :ok | :exception | :error

  @type t :: %__MODULE__{
          id: id(),
          parent_id: id() | nil,
          trace_id: id() | nil,
          type: atom(),
          name: atom(),
          status: status(),
          module: module() | nil,
          pid: pid() | nil,
          source: [atom()] | nil,
          monotonic_time: integer(),
          system_time: integer(),
          duration: non_neg_integer() | nil,
          measurements: %{optional(atom()) => number()},
          metadata: map()
        }

  @enforce_keys [:id, :type, :name, :monotonic_time, :system_time]
  defstruct [
    :id,
    :parent_id,
    :trace_id,
    :type,
    :name,
    :module,
    :pid,
    :source,
    :monotonic_time,
    :system_time,
    :duration,
    status: :ok,
    measurements: %{},
    metadata: %{}
  ]

  @fields [
    :id,
    :parent_id,
    :trace_id,
    :type,
    :name,
    :status,
    :module,
    :pid,
    :source,
    :monotonic_time,
    :system_time,
    :duration,
    :measurements,
    :metadata
  ]

  @doc """
  Builds a validated event.

  `:type` and `:name` are required. These defaults apply:

    * `:id` - a fresh `new_id/0`
    * `:pid` - `self()`. Telemetry handlers run in the process that emitted the
      event, so this is the observed process.
    * `:monotonic_time` and `:system_time` - now
    * `:status` - `:ok`

  Returns `{:error, reason}` instead of raising, because events are usually built
  inside telemetry handlers that run in the host application's processes.

  ## Examples

      iex> {:ok, event} = LiveViewVisualizer.Event.new(type: :live_view, name: :mount)
      iex> {event.type, event.name, event.status}
      {:live_view, :mount, :ok}

      iex> LiveViewVisualizer.Event.new(type: :live_view)
      {:error, {:missing_field, :name}}

  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with :ok <- check_unknown_fields(attrs),
         :ok <- check_required(attrs, :type),
         :ok <- check_required(attrs, :name) do
      attrs
      |> Map.put_new_lazy(:id, &new_id/0)
      |> Map.put_new_lazy(:pid, &self/0)
      |> Map.put_new_lazy(:monotonic_time, &System.monotonic_time/0)
      |> Map.put_new_lazy(:system_time, &System.system_time/0)
      |> then(&struct(__MODULE__, &1))
      |> validate()
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  @doc """
  Like `new/1` but raises `ArgumentError` on invalid input.

  Intended for tests and code that runs outside of the observed application's
  processes.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid event: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a new unique, positive, monotonically increasing identifier.

  Identifiers are unique within the running node only.
  """
  @spec new_id() :: id()
  def new_id, do: System.unique_integer([:positive, :monotonic])

  @doc """
  Returns the event duration converted to `unit`, or `nil` if there is none.

  ## Examples

      iex> native = System.convert_time_unit(1500, :millisecond, :native)
      iex> event = LiveViewVisualizer.Event.new!(type: :live_view, name: :mount, duration: native)
      iex> LiveViewVisualizer.Event.duration(event, :millisecond)
      1500

  """
  @spec duration(t(), System.time_unit()) :: non_neg_integer() | nil
  def duration(%__MODULE__{duration: nil}, _unit), do: nil

  def duration(%__MODULE__{duration: duration}, unit),
    do: System.convert_time_unit(duration, :native, unit)

  @doc """
  Returns the wall-clock start time of the event as a UTC `DateTime`.
  """
  @spec started_at(t()) :: DateTime.t()
  def started_at(%__MODULE__{system_time: system_time}) do
    system_time
    |> System.convert_time_unit(:native, :microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp check_unknown_fields(attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_fields, Enum.sort(unknown)}}
    end
  end

  defp check_required(attrs, key) do
    if Map.has_key?(attrs, key), do: :ok, else: {:error, {:missing_field, key}}
  end

  defp validate(%__MODULE__{} = event) do
    Enum.reduce_while(@fields, {:ok, event}, fn field, acc ->
      if valid?(field, Map.fetch!(event, field)) do
        {:cont, acc}
      else
        {:halt, {:error, {:invalid_field, field}}}
      end
    end)
  end

  defp valid?(:id, value), do: pos_integer?(value)
  defp valid?(:parent_id, value), do: is_nil(value) or pos_integer?(value)
  defp valid?(:trace_id, value), do: is_nil(value) or pos_integer?(value)
  defp valid?(:type, value), do: is_atom(value) and not is_nil(value)
  defp valid?(:name, value), do: is_atom(value) and not is_nil(value)
  defp valid?(:status, value), do: value in [:ok, :exception, :error]
  defp valid?(:module, value), do: is_atom(value)
  defp valid?(:pid, value), do: is_nil(value) or is_pid(value)

  defp valid?(:source, value),
    do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_atom/1))

  defp valid?(:monotonic_time, value), do: is_integer(value)
  defp valid?(:system_time, value), do: is_integer(value)
  defp valid?(:duration, value), do: is_nil(value) or (is_integer(value) and value >= 0)
  defp valid?(:measurements, value), do: is_map(value)
  defp valid?(:metadata, value), do: is_map(value)

  defp pos_integer?(value), do: is_integer(value) and value > 0
end
