defmodule LiveViewVisualizerWeb.FormatTest do
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.Event
  alias LiveViewVisualizerWeb.Format

  doctest Format

  describe "label/1" do
    test "names each kind of event" do
      assert Format.label(Event.new!(type: :live_view, name: :render)) == "render"

      assert Format.label(
               Event.new!(type: :live_view, name: :mount, metadata: %{connected?: true})
             ) ==
               "mount (connected)"

      assert Format.label(
               Event.new!(
                 type: :live_component,
                 name: :handle_event,
                 module: MyAppWeb.CartComponent,
                 metadata: %{event: "add"}
               )
             ) == ~s{handle_event("add") · CartComponent}

      assert Format.label(Event.new!(type: :ecto, name: :query, metadata: %{source: "products"})) ==
               "Ecto query · products"

      assert Format.label(Event.new!(type: :ecto, name: :query, metadata: %{source: nil})) ==
               "Ecto query"
    end
  end

  test "duration/1 picks a readable unit" do
    native = &System.convert_time_unit(&1, :microsecond, :native)

    assert Format.duration(nil) == "-"
    assert Format.duration(native.(5)) == "5µs"
    assert Format.duration(native.(1_234)) == "1.23ms"
    assert Format.duration(native.(250_000)) == "250ms"
    assert Format.duration(native.(2_500_000)) == "2.50s"
  end

  test "bar_width/2 is relative to the longest duration, with a visible minimum" do
    assert Format.bar_width(50, 100) == 50.0
    assert Format.bar_width(1, 10_000) == 0.5
    assert Format.bar_width(nil, 100) == 0.0
  end

  describe "details/3" do
    test "lists allowlisted fields, resolving the parent and child count" do
      parent =
        Event.new!(
          type: :live_view,
          name: :handle_event,
          module: MyAppWeb.InventoryLive,
          metadata: %{event: "search"}
        )

      query =
        Event.new!(
          type: :ecto,
          name: :query,
          module: MyApp.Repo,
          parent_id: parent.id,
          duration: System.convert_time_unit(13_200, :microsecond, :native),
          measurements: %{query_time: System.convert_time_unit(10_000, :microsecond, :native)},
          metadata: %{repo: MyApp.Repo, source: "products", command: :select, num_rows: 2}
        )

      details = Map.new(Format.details(query, %{parent.id => parent}, %{}))

      assert details["Type"] == "Ecto"
      assert details["Operation"] == "query"
      assert details["Repo"] == "MyApp.Repo"
      assert details["Source"] == "products"
      assert details["Command"] == "select"
      assert details["Rows"] == "2"
      assert details["Duration"] == "13.2ms"
      assert details["Query time"] == "10.0ms"
      assert details["Parent"] == ~s{handle_event("search") · InventoryLive (##{parent.id})}
      assert details["Children"] == "0"
      assert details["Status"] == "OK"

      assert Map.new(Format.details(parent, %{}, %{parent.id => 1}))["Children"] == "1"
    end

    test "marks a parent that is no longer in the buffer" do
      event = Event.new!(type: :ecto, name: :query, parent_id: 42)
      assert Map.new(Format.details(event, %{}, %{}))["Parent"] == "#42 (no longer in the buffer)"
    end

    test "shows the stored failure information" do
      event =
        Event.new!(
          type: :ecto,
          name: :query,
          status: :error,
          metadata: %{exception: Postgrex.Error, error_code: :undefined_table}
        )

      details = Map.new(Format.details(event, %{}, %{}))
      assert details["Status"] == "ERROR"
      assert details["Exception"] == "Postgrex.Error"
      assert details["Error code"] == "undefined_table"
    end

    test "never renders metadata outside the allowlist" do
      event =
        Event.new!(
          type: :my_lib,
          name: :work,
          metadata: %{secret_note: "never-shown", params: %{"password" => "x"}, query: "SELECT 1"}
        )

      rendered = event |> Format.details(%{}, %{}) |> inspect()

      for hidden <- ["never-shown", "password", "SELECT", "secret_note", "params"] do
        refute rendered =~ hidden
      end
    end
  end
end
