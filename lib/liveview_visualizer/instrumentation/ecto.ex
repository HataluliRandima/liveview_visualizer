defmodule LiveViewVisualizer.Instrumentation.Ecto do
  @moduledoc """
  Observes Ecto repository queries.

  Attached automatically by `LiveViewVisualizer.Telemetry` when the visualizer is
  enabled and `:ecto` is available. Repositories, schemas and contexts need no
  changes.

  ## Observed events

  Ecto does **not** emit a fixed `[:ecto, :repo, :query]` event. Every
  repository emits `telemetry_prefix ++ [:query]`. The prefix is derived from the
  repo module by default (`MyApp.Repo` → `[:my_app, :repo]`) and can be changed
  per repo. It is a single event emitted after the query finished, not a span.
  Query event names are therefore discovered at runtime:

    * `[:ecto, :repo, :init]` is emitted by every repo as it starts, *before*
      its connection pool starts, and its metadata includes the final
      `:telemetry_prefix`. The handler returns `{:attach, [prefix ++ [:query]]}`,
      so the repo's query event is attached before the repo can run its first
      query. Every repo is handled independently, so any number of repos works.
    * Repos that were already running when this instrumentation was attached
      (for example after the visualizer restarted) are found with
      `Ecto.Repo.all_running/0`, and their prefix is read with the public
      `repo.config/0`. Dynamic repos registered only by pid are not discovered
      this way.

  Verified against Ecto / Ecto SQL 3.10 to 3.14, which emit the same metadata.

  ## Recorded event

  Each query becomes `type: :ecto`, `name: :query`, `module: repo`:

    * `duration` - `:total_time` (queue + query + decode), in native units
    * `measurements` - `:query_time`, `:queue_time`, `:decode_time`, `:idle_time`
      when present
    * `status` - `:ok`, or `:error` when the result is `{:error, _}`. The query
      completed and the database (or the connection) reported a failure. Ecto
      SQL reports raised errors this way too. Whatever the application does
      next (raise, return a changeset error) is unaffected.
    * `parent_id` / `trace_id` - the LiveView callback running in the same
      process, if any (see `LiveViewVisualizer.Context`), otherwise `nil`.

  ## Metadata

  Only structural fields are copied out of the telemetry metadata:

    * `:repo` - the repo module
    * `:source` - the table the query was built from, as reported by Ecto
      (`nil` for raw SQL, transaction commands and similar). SQL is never parsed.
      Ecto SQL reports it for reads in all supported versions, and for
      inserts, updates and deletes only from 3.11.0.
    * `:command` - the command reported by the driver's result, such as
      `:select`, `:insert` or `:begin`, when the driver provides one (Postgrex does)
    * `:num_rows` - number of rows returned or affected, when provided. The rows
      themselves are never read.
    * `:exception` - on failure, the exception module (e.g. `Postgrex.Error`)
    * `:error_code` - on failure, the database error code when the driver exposes
      one as an atom (Postgrex: `:unique_violation`, `:undefined_table`, ...)

  **Never stored:** the SQL text (`:query`), `:params`, `:cast_params`, result
  rows, `:stacktrace`, `:options` (user-supplied `:telemetry_options`) and
  exception messages, which can contain parameter values.
  """

  @behaviour LiveViewVisualizer.Instrumentation

  alias LiveViewVisualizer.{Context, Event}

  # Ecto is only present when the host application uses it.
  @compile {:no_warn_undefined, Ecto.Repo}

  @init_event [:ecto, :repo, :init]
  @measurements [:query_time, :queue_time, :decode_time, :idle_time]

  @impl true
  def events do
    if Code.ensure_loaded?(Ecto.Repo),
      do: [@init_event | running_repo_events()],
      else: []
  end

  @impl true
  def handle_event(@init_event, _measurements, %{opts: opts}) do
    case query_event_name(opts) do
      nil -> :ignore
      event -> {:attach, [event]}
    end
  end

  def handle_event([_ | _] = source, measurements, %{repo: repo} = metadata)
      when is_atom(repo) and is_map(measurements) do
    if List.last(source) == :query,
      do: build_event(source, measurements, metadata),
      else: :ignore
  end

  def handle_event(_event, _measurements, _metadata), do: :ignore

  defp build_event(source, measurements, metadata) do
    duration = total_time(measurements)
    start_time = System.monotonic_time() - duration
    result = Map.get(metadata, :result)
    repo = metadata.repo

    Event.new!(
      Map.to_list(Context.current() || %{}) ++
        [
          type: :ecto,
          name: :query,
          status: status(result),
          module: repo,
          source: source,
          monotonic_time: start_time,
          system_time: start_time + System.time_offset(),
          duration: duration,
          measurements: Map.take(measurements, @measurements),
          metadata:
            Map.merge(
              %{repo: repo, source: string_or_nil(Map.get(metadata, :source))},
              result_fields(result)
            )
        ]
    )
  end

  defp total_time(%{total_time: total}) when is_integer(total) and total >= 0, do: total

  defp total_time(measurements) do
    for {key, value} <- measurements,
        key in [:query_time, :queue_time, :decode_time],
        is_integer(value),
        reduce: 0,
        do: (acc -> acc + value)
  end

  defp status({:error, _}), do: :error
  defp status(_result), do: :ok

  # Results and errors are driver structs. Only these fields are read; rows,
  # columns and messages are never touched.
  defp result_fields({:ok, result}) do
    %{
      command: atom_field(result, :command),
      num_rows: integer_field(result, :num_rows)
    }
  end

  defp result_fields({:error, error}) do
    %{exception: exception_module(error), error_code: error_code(error)}
  end

  defp result_fields(_result), do: %{}

  defp exception_module(%{__exception__: true, __struct__: module}), do: module
  defp exception_module(_error), do: nil

  # Driver-specific, isolated here: Postgrex exposes the SQLSTATE as an atom.
  defp error_code(%{postgres: %{code: code}}) when is_atom(code) and not is_nil(code), do: code
  defp error_code(_error), do: nil

  defp atom_field(%{} = map, key) do
    case Map.get(map, key) do
      value when is_atom(value) and not is_nil(value) -> value
      _ -> nil
    end
  end

  defp atom_field(_result, _key), do: nil

  defp integer_field(%{} = map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp integer_field(_result, _key), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp query_event_name(opts) when is_list(opts) do
    case Keyword.get(opts, :telemetry_prefix) do
      [_ | _] = prefix -> if Enum.all?(prefix, &is_atom/1), do: prefix ++ [:query]
      _ -> nil
    end
  end

  defp query_event_name(_opts), do: nil

  # Repos started before this instrumentation was attached. repo.config/0 is
  # public, but runs the repo's init/2 callback, so any failure skips that repo.
  defp running_repo_events do
    running_repos()
    |> Enum.flat_map(fn repo ->
      case running_repo_event(repo) do
        nil -> []
        event -> [event]
      end
    end)
    |> Enum.uniq()
  end

  # Ecto.Repo.all_running/0 reads Ecto's registry table, which only exists
  # while the :ecto application is running.
  defp running_repos do
    Enum.filter(Ecto.Repo.all_running(), &is_atom/1)
  rescue
    _ -> []
  end

  defp running_repo_event(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0),
      do: query_event_name(repo.config())
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
