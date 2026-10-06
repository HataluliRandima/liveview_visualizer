defmodule LiveViewVisualizer.StoreTest do
  # Uses the application's singleton store (capacity 100, see config/test.exs).
  use ExUnit.Case, async: false

  import LiveViewVisualizer.SupervisionHelpers

  alias LiveViewVisualizer.{Event, Store}

  @capacity 100

  setup do
    Store.clear()
    :ok
  end

  defp event(i), do: Event.new!(type: :test, name: :store, metadata: %{i: i})

  defp indexes(events), do: Enum.map(events, & &1.metadata.i)

  test "an empty store returns no events" do
    assert Store.recent() == []
    assert Store.recent(10) == []
    assert Store.count() == 0
  end

  test "records events and returns them oldest first" do
    events = for i <- 1..3, do: event(i)

    for e <- events, do: assert(Store.record(e) == :ok)

    assert Store.recent() == events
    assert Store.count() == 3
  end

  test "recent/1 returns only the most recent events" do
    for i <- 1..10, do: Store.record(event(i))

    assert indexes(Store.recent(3)) == [8, 9, 10]
    assert indexes(Store.recent(1)) == [10]
    assert indexes(Store.recent(50)) == Enum.to_list(1..10)
  end

  test "recent/1 rejects invalid limits" do
    assert_raise FunctionClauseError, fn -> Store.recent(0) end
    assert_raise FunctionClauseError, fn -> Store.recent(-1) end
  end

  test "retains at most the configured number of events, dropping the oldest" do
    assert Store.capacity() == @capacity

    for i <- 1..250, do: Store.record(event(i))

    assert Store.count() == @capacity
    assert indexes(Store.recent()) == Enum.to_list(151..250)
    assert indexes(Store.recent(1_000)) == Enum.to_list(151..250)
  end

  test "keeps every event from concurrent writers while under capacity" do
    1..10
    |> Enum.map(fn writer ->
      Task.async(fn -> for n <- 1..10, do: Store.record(event({writer, n})) end)
    end)
    |> Task.await_many()

    recorded = indexes(Store.recent())

    assert length(recorded) == 100
    assert Enum.sort(recorded) == Enum.sort(for w <- 1..10, n <- 1..10, do: {w, n})
  end

  test "stays bounded and consistent under concurrent writes and reads beyond capacity" do
    writers =
      for writer <- 1..20 do
        Task.async(fn ->
          for n <- 1..500, do: :ok = Store.record(event({writer, n}))
        end)
      end

    readers =
      for _ <- 1..4 do
        Task.async(fn ->
          for _ <- 1..200 do
            events = Store.recent()
            assert length(events) <= @capacity
            assert length(Enum.uniq_by(events, & &1.id)) == length(events)
          end
        end)
      end

    Task.await_many(writers ++ readers, 30_000)

    events = Store.recent()

    # Memory stays bounded: one row per slot, never more.
    assert Store.count() == @capacity
    assert length(events) <= @capacity
    assert length(Enum.uniq_by(events, & &1.id)) == length(events)

    # Each writer's own events come back in the order it wrote them.
    for {_writer, ns} <- events |> indexes() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) do
      assert ns == Enum.sort(ns)
    end

    # After the burst, the ring buffer is fully consistent again.
    for i <- 1..@capacity, do: Store.record(event(i))
    assert indexes(Store.recent()) == Enum.to_list(1..@capacity)
  end

  test "clear/0 removes all events and the store keeps working" do
    for i <- 1..5, do: Store.record(event(i))

    assert Store.clear() == :ok
    assert Store.recent() == []
    assert Store.count() == 0

    Store.record(event(6))
    assert indexes(Store.recent()) == [6]
  end

  test "returns errors and empty results instead of raising when not running" do
    stop_child(Store)

    assert Store.record(event(1)) == {:error, :not_running}
    assert Store.recent() == []
    assert Store.count() == 0
    assert Store.capacity() == nil
    assert Store.clear() == :ok
  end

  test "is restarted empty by its supervisor after a crash" do
    Store.record(event(1))
    old_pid = Process.whereis(Store)

    Process.exit(old_pid, :kill)
    await_restart(Store, old_pid)

    assert Store.recent() == []
    assert Store.record(event(2)) == :ok
    assert indexes(Store.recent()) == [2]
  end
end
