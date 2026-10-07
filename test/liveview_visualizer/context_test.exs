defmodule LiveViewVisualizer.ContextTest do
  # Bumps the global epoch, so it must not run concurrently with other tests
  # that depend on correlation.
  use ExUnit.Case, async: false

  alias LiveViewVisualizer.Context

  @key {Context, :stack}

  setup do
    Process.delete(@key)
    :ok
  end

  test "top-level spans have no parent and are their own trace" do
    ctx = make_ref()

    %{id: id} = ids = Context.enter(ctx)
    assert ids == %{id: id, parent_id: nil, trace_id: id}
    assert Context.current() == %{parent_id: id, trace_id: id}

    assert Context.exit(ctx) == ids
    assert Context.current() == nil
  end

  test "nested spans form a parent chain within one trace" do
    outer = make_ref()
    inner = make_ref()

    %{id: outer_id} = Context.enter(outer)
    %{id: inner_id} = inner_ids = Context.enter(inner)

    assert inner_ids == %{id: inner_id, parent_id: outer_id, trace_id: outer_id}
    assert Context.current() == %{parent_id: inner_id, trace_id: outer_id}

    assert Context.exit(inner) == inner_ids
    assert Context.current() == %{parent_id: outer_id, trace_id: outer_id}

    assert %{id: ^outer_id} = Context.exit(outer)
    assert Context.current() == nil
  end

  test "nothing is left in the process dictionary after the outermost span ends" do
    ctx = make_ref()
    Context.enter(ctx)
    assert Process.get(@key) != nil

    Context.exit(ctx)
    assert Process.get(@key) == nil
  end

  test "an end without a known start returns nil and leaves the stack untouched" do
    ctx = make_ref()
    %{id: id} = Context.enter(ctx)

    assert Context.exit(make_ref()) == nil
    assert Context.current() == %{parent_id: id, trace_id: id}

    Context.exit(ctx)
  end

  test "ending an outer span also discards inner spans whose end was missed" do
    outer = make_ref()
    Context.enter(outer)
    Context.enter(make_ref())

    assert %{parent_id: nil} = Context.exit(outer)
    assert Context.current() == nil
    assert Process.get(@key) == nil
  end

  test "the stack is bounded; spans beyond the limit get no children" do
    contexts = for _ <- 1..20, do: make_ref()
    Enum.each(contexts, &Context.enter/1)

    assert length(Process.get(@key)) == 8

    # The 9th and later spans were not tracked, so ending them returns nil...
    assert contexts |> Enum.drop(8) |> Enum.reverse() |> Enum.map(&Context.exit/1) |> Enum.uniq() ==
             [nil]

    # ...while the tracked ones still unwind correctly.
    assert contexts |> Enum.take(8) |> Enum.reverse() |> Enum.all?(&is_map(Context.exit(&1)))
    assert Process.get(@key) == nil
  end

  test "spans from an older epoch are never used as parents" do
    ctx = make_ref()
    Context.enter(ctx)
    assert Context.current() != nil

    # Handlers were attached or detached while the span was running.
    Context.bump_epoch()

    assert Context.current() == nil
    assert Process.get(@key) == nil

    # A new span after the change starts a fresh, valid stack.
    fresh = make_ref()
    %{id: id} = Context.enter(fresh)
    assert Context.current() == %{parent_id: id, trace_id: id}
    Context.exit(fresh)
  end

  test "contexts are private to each process" do
    ctx = make_ref()
    Context.enter(ctx)

    assert Task.async(fn -> Context.current() end) |> Task.await() == nil

    Context.exit(ctx)
  end
end
