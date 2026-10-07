defmodule LiveViewVisualizer.Instrumentation.EctoTest do
  # Unit tests for event discovery and metadata extraction. The integration
  # tests in ecto_integration_test.exs run real queries against PostgreSQL.
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.Event
  alias LiveViewVisualizer.Instrumentation.Ecto, as: Instrumentation
  alias LiveViewVisualizer.TestRepo

  @query_event [:live_view_visualizer, :test_repo, :query]

  # Metadata shaped exactly like Ecto SQL's, full of sensitive data.
  defp metadata(overrides \\ %{}) do
    Map.merge(
      %{
        type: :ecto_sql_query,
        repo: TestRepo,
        result:
          {:ok,
           %Postgrex.Result{
             command: :select,
             num_rows: 1,
             columns: ["email"],
             rows: [["row-secret@example.com"]]
           }},
        params: ["param-secret"],
        cast_params: ["cast-secret"],
        query: ~s{SELECT u0."email" FROM "users" AS u0 WHERE (u0."api_token" = $1)},
        source: "users",
        stacktrace: [{MyApp.Accounts, :get_by_token, 1, [file: ~c"lib/accounts.ex", line: 1]}],
        options: [tenant: "options-secret"]
      },
      overrides
    )
  end

  defp measurements do
    %{total_time: 1_500, query_time: 1_000, queue_time: 300, decode_time: 200, idle_time: 50}
  end

  describe "events/0" do
    test "listens for repo initialization and the query events of running repos" do
      events = Instrumentation.events()

      assert [:ecto, :repo, :init] in events
      # Both test repos are running; one uses the default prefix, one a custom one.
      assert @query_event in events
      assert [:analytics, :db, :query] in events
    end
  end

  describe "handle_event/3 for [:ecto, :repo, :init]" do
    test "requests attachment of the repo's actual query event" do
      assert Instrumentation.handle_event(
               [:ecto, :repo, :init],
               %{system_time: 0},
               %{repo: TestRepo, opts: [telemetry_prefix: [:my_app, :repo], password: "x"]}
             ) == {:attach, [[:my_app, :repo, :query]]}
    end

    test "ignores repos without a usable prefix" do
      for opts <- [[], [telemetry_prefix: []], [telemetry_prefix: ["bad"]], :not_a_list] do
        assert Instrumentation.handle_event([:ecto, :repo, :init], %{}, %{
                 repo: TestRepo,
                 opts: opts
               }) ==
                 :ignore
      end
    end
  end

  describe "handle_event/3 for query events" do
    test "keeps only structural metadata and numeric timings" do
      event = Instrumentation.handle_event(@query_event, measurements(), metadata())

      assert %Event{type: :ecto, name: :query, status: :ok, module: TestRepo} = event
      assert event.source == @query_event
      assert event.duration == 1_500

      assert event.measurements == %{
               query_time: 1_000,
               queue_time: 300,
               decode_time: 200,
               idle_time: 50
             }

      assert event.metadata == %{
               repo: TestRepo,
               source: "users",
               command: :select,
               num_rows: 1
             }

      stored = inspect(event, limit: :infinity, printable_limit: :infinity)

      for secret <-
            ~w(row-secret param-secret cast-secret options-secret api_token SELECT accounts.ex) do
        refute stored =~ secret
      end
    end

    test "records database errors as :error with the exception module and code only" do
      error = %Postgrex.Error{
        message: nil,
        postgres: %{
          code: :unique_violation,
          detail: "Key (email)=(detail-secret@example.com) already exists.",
          message: "duplicate key value violates unique constraint"
        }
      }

      event =
        Instrumentation.handle_event(
          @query_event,
          measurements(),
          metadata(%{result: {:error, error}})
        )

      assert event.status == :error
      assert event.metadata.exception == Postgrex.Error
      assert event.metadata.error_code == :unique_violation
      refute inspect(event, limit: :infinity) =~ "detail-secret"
    end

    test "handles queries without a source, result details or a total time" do
      event =
        Instrumentation.handle_event(
          @query_event,
          %{query_time: 10, decode_time: 5},
          metadata(%{source: nil, result: {:ok, :not_a_struct}})
        )

      assert event.duration == 15
      assert event.metadata == %{repo: TestRepo, source: nil, command: nil, num_rows: nil}
    end

    test "has no parent outside of a tracked LiveView callback" do
      event = Instrumentation.handle_event(@query_event, measurements(), metadata())
      assert event.parent_id == nil and event.trace_id == nil
    end

    test "ignores events that are not query events" do
      assert Instrumentation.handle_event([:my_app, :repo, :other], measurements(), metadata()) ==
               :ignore

      assert Instrumentation.handle_event([:my_app, :repo, :query], %{}, %{}) == :ignore
    end
  end
end
