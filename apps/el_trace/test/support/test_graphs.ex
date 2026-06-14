defmodule ElTrace.TestGraphs do
  @moduledoc false
  # ElTrace LiveView 테스트용 그래프 픽스처. 인터럽트(사람 승인) → 완료 흐름을 가진
  # 최소 그래프 — eltrace_demo의 송금 승인 시나리오를 축약한 형태.

  @doc """
  plan → approve(interrupt) → finish 그래프.

  `:approve`에서 `Ctx.interrupt(%{question: "name?"})`로 멈추고, resume 값이 주입되면
  `finish`까지 진행해 완료된다. fork(여기서 분기)·승인/거절 테스트에 쓴다.
  """
  def approval_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:plan, &ElTrace.TestNodes.noop/2)
    |> ElGraph.add_node(:approve, &ElTrace.TestNodes.ask/2)
    |> ElGraph.add_node(:finish, &ElTrace.TestNodes.noop/2)
    |> ElGraph.add_edge(:plan, :approve)
    |> ElGraph.add_edge(:approve, :finish)
    |> ElGraph.compile(entry: :plan)
  end
end
