defmodule ElTrace.TimelineTest do
  use ExUnit.Case, async: true

  alias ElTrace.Timeline
  alias ElTrace.TestNodes
  alias ElGraph.Checkpointer.ETS

  # list가 보고한 step이 get 시점엔 사라진 경우(동시 pruning/완료) — TOCTOU.
  defmodule VanishingCP do
    def list(_config, _thread_id), do: [%{step: 0, version: 1}]
    def get(_config, _thread_id, _step), do: :not_found
  end

  defp ask_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:ask, &TestNodes.ask/2)
    |> ElGraph.compile(entry: :ask)
  end

  setup do
    pid = start_supervised!(ETS)
    %{cp: {ETS, ETS.config(pid)}}
  end

  describe "build/2 — #1 인터럽트 가시성" do
    test "shows the interrupt with node and payload", %{cp: cp} do
      graph = ask_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t1")

      events = Timeline.build(cp, "t1")

      assert Enum.any?(
               events,
               &match?(%{kind: :interrupt, node: :ask, payload: %{question: "name?"}}, &1)
             )
    end
  end

  describe "build/2 — #2 thread 생애" do
    test "interrupt remains visible after resume, plus a completion event", %{cp: cp} do
      graph = ask_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t2")
      {:ok, _} = ElGraph.resume(graph, checkpointer: cp, thread_id: "t2", resume: "Alice")

      events = Timeline.build(cp, "t2")

      # invoke→interrupt→resume 전체 생애: 인터럽트 기록이 남고 완료까지 보인다.
      assert Enum.any?(events, &match?(%{kind: :interrupt, node: :ask}, &1))
      assert Enum.any?(events, &match?(%{kind: :done}, &1))
      # step 오름차순
      steps = Enum.map(events, & &1.step)
      assert steps == Enum.sort(steps)
    end
  end

  describe "build/2 — 생성 시각(:at)" do
    test "각 이벤트가 체크포인트 생성 시각(ms)을 담는다", %{cp: cp} do
      graph = ask_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t-at")

      events = Timeline.build(cp, "t-at")

      assert events != []
      assert Enum.all?(events, &is_integer(&1.at))
    end
  end

  describe "build/2 — resilience" do
    test "skips checkpoints that vanish between list and get (no crash)" do
      assert Timeline.build({VanishingCP, :cfg}, "t") == []
    end
  end

  describe "render/1" do
    test "renders a readable timeline with interrupt and done markers", %{cp: cp} do
      graph = ask_graph()
      {:interrupted, _} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: "t3")
      {:ok, _} = ElGraph.resume(graph, checkpointer: cp, thread_id: "t3", resume: "Bob")

      text = cp |> Timeline.build("t3") |> Timeline.render()

      assert text =~ "interrupt"
      assert text =~ "ask"
      assert text =~ "done"
    end
  end
end
