defmodule ElGraph.ConcurrencyTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Reducers, TestNodes}

  # 시작을 알리고 :go를 받을 때까지 블록한다 — 동시 실행 여부를 메시지로 관찰하기 위함.
  def gated(%{item: item}, _ctx, test) do
    send(test, {:started, item, self()})

    receive do
      :go -> :ok
    end

    %{results: [item]}
  end

  # :plan이 [1,2,3]을 :worker로 fan-out → 세 인스턴스가 동시에 게이트에 걸린다.
  defp fanout_graph do
    {graph, _warning} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        ElGraph.new()
        |> ElGraph.state(:results, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:plan, {TestNodes, :plan_sends, [[1, 2, 3], :worker]})
        |> ElGraph.add_node(:worker, {__MODULE__, :gated, [self()]})
        |> ElGraph.compile(entry: :plan)
      end)

    graph
  end

  describe ":max_concurrency (SPEC §3.4)" do
    test "max_concurrency: 1 runs fan-out nodes one at a time" do
      graph = fanout_graph()
      task = Task.async(fn -> ElGraph.invoke(graph, %{}, max_concurrency: 1) end)

      # 한 번에 하나만 시작 가능 — 다음 인스턴스는 앞이 끝나기 전엔 시작하지 못한다.
      # (양성 수신은 전체 스위트 병렬 부하에서 스케줄 지연을 견디게 넉넉히 기다린다.)
      assert_receive {:started, 1, p1}, 1_000
      refute_receive {:started, _, _}, 50
      send(p1, :go)

      assert_receive {:started, 2, p2}, 1_000
      refute_receive {:started, _, _}, 50
      send(p2, :go)

      assert_receive {:started, 3, p3}, 1_000
      send(p3, :go)

      assert {:ok, %{results: results}} = Task.await(task, 1_000)
      assert [1, 2, 3] = Enum.sort(results)
    end

    test "max_concurrency raises the limit so fan-out runs concurrently" do
      graph = fanout_graph()
      task = Task.async(fn -> ElGraph.invoke(graph, %{}, max_concurrency: 3) end)

      # 셋 다 서로의 :go를 기다리지 않고 동시에 시작할 수 있어야 한다.
      assert_receive {:started, _, p1}, 1_000
      assert_receive {:started, _, p2}, 1_000
      assert_receive {:started, _, p3}, 1_000

      for p <- [p1, p2, p3], do: send(p, :go)

      assert {:ok, %{results: results}} = Task.await(task, 1_000)
      assert [1, 2, 3] = Enum.sort(results)
    end

    test "propagates into subgraphs so nested fan-out also respects the limit" do
      sub = fanout_graph()

      graph =
        ElGraph.new()
        |> ElGraph.state(:results, default: [], reducer: {Reducers, :append, []})
        |> ElGraph.add_node(:sub, sub)
        |> ElGraph.compile(entry: :sub)

      task = Task.async(fn -> ElGraph.invoke(graph, %{}, max_concurrency: 1) end)

      # 서브그래프 내부 fan-out도 부모의 상한(1)을 따라 직렬화돼야 한다 —
      # 안 그러면 중첩 fan-out에서 동시성이 곱해진다.
      assert_receive {:started, 1, p1}, 1_000
      refute_receive {:started, _, _}, 50
      send(p1, :go)

      assert_receive {:started, 2, p2}, 1_000
      send(p2, :go)

      assert_receive {:started, 3, p3}, 1_000
      send(p3, :go)

      assert {:ok, _} = Task.await(task, 1_000)
    end
  end

  describe ":max_concurrency validation" do
    defp single_node_graph do
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:a, &TestNodes.noop/2)
      |> ElGraph.compile(entry: :a)
    end

    test "rejects a non-positive-integer max_concurrency up front" do
      # 잘못된 값은 fan-out이 일어나기 전에(빌드 시점) 거부돼야 한다 — 단일 노드 그래프라
      # async_stream을 타지 않으므로, 가드가 없으면 그냥 {:ok}로 통과해 버린다.
      assert_raise ArgumentError, ~r/max_concurrency/, fn ->
        ElGraph.invoke(single_node_graph(), %{}, max_concurrency: 0)
      end

      assert_raise ArgumentError, ~r/max_concurrency/, fn ->
        ElGraph.invoke(single_node_graph(), %{}, max_concurrency: :lots)
      end
    end
  end
end
