# Database dependencies are test-only and not runtime applications of the
# library, so they are started here.
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

{:ok, _} = LiveViewVisualizer.TestApp.Endpoint.start_link()

exclude =
  case LiveViewVisualizer.TestDB.setup() do
    :ok ->
      []

    {:error, reason} ->
      IO.puts(:stderr, """

      *** PostgreSQL is not available (#{inspect(reason)}).
      *** Tests tagged :postgres are EXCLUDED. Set LVV_DATABASE_URL to run them.
      """)

      [:postgres]
  end

ExUnit.start(exclude: exclude)
