defmodule ElGraph.MemoTest do
  use ExUnit.Case, async: true

  alias ElGraph.Ctx
  alias ElGraph.Checkpointer.ETS
  alias ElGraph.{Reducers, TestNodes}

  # fan-out 인스턴스가 자신의 node_key를 상태로 기록한다 — 인스턴스별 격리 검증용.
  def record_node_key(%{item: item}, ctx, _opts), do: %{seen: [{item, ctx.node_key}]}

  # memo로 감싼 "비싼 호출"(LLM/툴 모사)은 table의 :calls 카운터를 증가시킨다.
  # interrupt 후 resume 시 노드가 처음부터 재실행되지만, memo는 재실행되면 안 된다.
  def memo_then_interrupt(_state, ctx, table) do
    val =
      Ctx.memo(ctx, :llm, fn ->
        :ets.update_counter(table, :calls, 1, {:calls, 0})
        "answer-from-llm"
      end)

    decision = Ctx.interrupt(ctx, %{ask: "approve?"})
    %{result: {val, decision}}
  end

  # 같은 노드 안에서 같은 key를 두 번 memo → fun은 한 번만 실행.
  def memo_twice(_state, ctx, table) do
    a = Ctx.memo(ctx, :k, fn -> :ets.update_counter(table, :calls, 1, {:calls, 0}) && "a" end)
    b = Ctx.memo(ctx, :k, fn -> :ets.update_counter(table, :calls, 1, {:calls, 0}) && "b" end)
    %{result: {a, b}}
  end

  test "memo without a task cache just runs the function" do
    assert "x" = Ctx.memo(%Ctx{node: :n}, :k, fn -> "x" end)
  end

  test "memo isolates instances that share a task cache but differ by node_key" do
    tid = :ets.new(:memo_fanout, [:set, :public])
    i0 = %Ctx{node: :worker, node_key: {:worker, 0}, task_cache: tid}
    i1 = %Ctx{node: :worker, node_key: {:worker, 1}, task_cache: tid}

    assert 10 = Ctx.memo(i0, :work, fn -> 10 end)

    # 같은 노드·같은 key지만 다른 인스턴스 → 첫 인스턴스 값을 공유하지 않고 자기 값을 계산한다.
    assert 20 = Ctx.memo(i1, :work, fn -> 20 end)
  end

  test "fan-out instances of the same node receive distinct node_keys" do
    table = :ets.new(:memo_fanout_calls, [:public])

    {graph, _warning} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        ElGraph.new()
        |> ElGraph.state(:seen, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:plan, {TestNodes, :plan_sends, [[1, 2], :worker]})
        |> ElGraph.add_node(:worker, {__MODULE__, :record_node_key, [table]})
        |> ElGraph.compile(entry: :plan)
      end)

    assert {:ok, %{seen: seen}} = ElGraph.invoke(graph, %{})
    assert [{1, k1}, {2, k2}] = Enum.sort(seen)
    # 두 인스턴스의 node_key가 달라야 memo 캐시가 충돌하지 않는다.
    assert k1 != k2
  end

  test "memo runs the function once per key within a node run" do
    table = :ets.new(:memo_twice, [:public])

    graph =
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:work, {__MODULE__, :memo_twice, [table]})
      |> ElGraph.compile(entry: :work)

    assert {:ok, %{result: {"a", "a"}}} = ElGraph.invoke(graph, %{}, thread_id: "tw")
    assert [{:calls, 1}] = :ets.lookup(table, :calls)
  end

  test "replay does not re-run memoized work across interrupt + resume" do
    table = :ets.new(:memo_replay, [:public])
    cp_pid = start_supervised!(ETS)
    cp = {ETS, ETS.config(cp_pid)}

    graph =
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:work, {__MODULE__, :memo_then_interrupt, [table]})
      |> ElGraph.compile(entry: :work)

    assert {:interrupted, _} =
             ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "m1")

    assert [{:calls, 1}] = :ets.lookup(table, :calls)

    assert {:ok, %{result: {"answer-from-llm", :approved}}} =
             ElGraph.resume(graph, checkpointer: cp, thread_id: "m1", resume: :approved)

    # 핵심: 재개 시 노드는 재실행되지만 memo는 캐시 → :calls 여전히 1.
    assert [{:calls, 1}] = :ets.lookup(table, :calls)
  end
end
