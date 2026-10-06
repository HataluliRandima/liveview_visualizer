defmodule LiveViewVisualizer.EventTest do
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.Event

  doctest Event

  describe "new/1" do
    test "builds an event with sensible defaults" do
      before_mono = System.monotonic_time()
      before_sys = System.system_time()

      assert {:ok, %Event{} = event} = Event.new(type: :live_view, name: :mount)

      assert event.type == :live_view
      assert event.name == :mount
      assert event.status == :ok
      assert event.pid == self()
      assert is_integer(event.id) and event.id > 0
      assert event.monotonic_time >= before_mono
      assert event.system_time >= before_sys
      assert event.duration == nil
      assert event.parent_id == nil
      assert event.trace_id == nil
      assert event.metadata == %{}
      assert event.measurements == %{}
    end

    test "accepts a map and keeps every explicitly given field" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        id: 10,
        parent_id: 5,
        trace_id: 1,
        type: :live_view,
        name: :handle_event,
        status: :error,
        module: MyAppWeb.PageLive,
        pid: pid,
        source: [:phoenix, :live_view, :handle_event, :exception],
        monotonic_time: -123,
        system_time: 456,
        duration: 789,
        measurements: %{duration: 789},
        metadata: %{event: "save"}
      }

      assert {:ok, event} = Event.new(attrs)
      assert Map.from_struct(event) == attrs
    end

    test "supports correlating events through parent_id and trace_id" do
      root = Event.new!(type: :live_view, name: :handle_event)
      child = Event.new!(type: :ecto, name: :query, parent_id: root.id, trace_id: root.id)

      assert child.parent_id == root.id
      assert child.trace_id == root.id
      assert child.id > root.id
    end

    test "requires type and name" do
      assert Event.new(name: :mount) == {:error, {:missing_field, :type}}
      assert Event.new(type: :live_view) == {:error, {:missing_field, :name}}
    end

    test "rejects unknown fields" do
      assert Event.new(type: :t, name: :n, foo: 1, bar: 2) ==
               {:error, {:unknown_fields, [:bar, :foo]}}
    end

    test "rejects invalid field values" do
      invalid = [
        id: 0,
        parent_id: -1,
        trace_id: "abc",
        type: "live_view",
        name: nil,
        status: :weird,
        module: "MyModule",
        pid: "not a pid",
        source: ["phoenix"],
        monotonic_time: 1.5,
        system_time: nil,
        duration: -1,
        measurements: [],
        metadata: "secret"
      ]

      for {field, value} <- invalid do
        attrs = Keyword.merge([type: :t, name: :n], [{field, value}])

        assert Event.new(attrs) == {:error, {:invalid_field, field}},
               "expected #{field}: #{inspect(value)} to be rejected"
      end
    end

    test "rejects non-enumerable attributes" do
      assert Event.new("nope") == {:error, :invalid_attributes}
    end
  end

  test "new!/1 raises ArgumentError on invalid input" do
    assert_raise ArgumentError, ~r/missing_field/, fn -> Event.new!(type: :t) end
  end

  test "new_id/0 returns unique, increasing positive integers" do
    ids = for _ <- 1..1_000, do: Event.new_id()

    assert Enum.all?(ids, &(&1 > 0))
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)
  end

  test "duration/2 converts native units and handles missing durations" do
    native = System.convert_time_unit(2, :second, :native)

    assert Event.duration(Event.new!(type: :t, name: :n, duration: native), :millisecond) == 2_000
    assert Event.duration(Event.new!(type: :t, name: :n), :millisecond) == nil
  end

  test "started_at/1 returns the wall-clock start as a UTC DateTime" do
    event = Event.new!(type: :t, name: :n)

    assert %DateTime{time_zone: "Etc/UTC"} = started_at = Event.started_at(event)
    # Compare against Erlang system time (what events use), not OS time:
    # the two can legitimately differ while the VM corrects time warps.
    now = DateTime.from_unix!(System.system_time(:microsecond), :microsecond)
    assert DateTime.diff(now, started_at, :millisecond) in 0..1_000
  end
end
