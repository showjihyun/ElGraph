defmodule ObservedAgent do
  @moduledoc """
  el_graph + el_trace를 의존성으로 끌어다 쓰는 예제 호스트 앱.

  그래프를 실행해 사람 승인 인터럽트까지 보낸 뒤 `ElTrace.observe/3`로 등록한다.
  부팅하면 el_trace(의존성)의 LiveView가 http://localhost:4000 에서 뜨고, 이 thread가 보인다 —
  거기서 승인/거절·여기서 분기를 할 수 있다.
  """

  alias ElGraph.Checkpointer.ETS

  @thread "consumer-결제-승인"

  @doc """
  그래프를 인터럽트까지 실행해 등록하고, 같은 지점에서 "거절" 분기를 만든다
  (Application에서 부팅 시 호출). UI에는 두 thread가 보인다:

    * `consumer-결제-승인`        — 승인 대기(인터럽트) 그대로, 직접 승인/거절/분기 가능
    * `consumer-결제-승인-거절`   — 같은 지점에서 분기해 "거절"로 완료된 if 시나리오
  """
  def seed do
    cp = {ETS, ETS.config(ObservedAgent.Checkpointer)}
    graph = approval_graph()

    with {:interrupted, %{step: step}} <-
           ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: @thread),
         :ok <- ElTrace.observe(@thread, graph, cp) do
      reject_branch(graph, cp, step)
    end
  end

  # "여기서 분기"(ElTrace.fork)의 코드 버전 — 인터럽트 지점에서 분기 후 "거절"로 resume한다.
  # 원본(@thread)은 승인 대기 그대로 보존된다 (time-travel: 원본 불변).
  defp reject_branch(graph, cp, step) do
    {:ok, fork_id, {:interrupted, _}} = ElTrace.fork(@thread, step, as: "#{@thread}-거절")
    ElGraph.resume(graph, checkpointer: cp, thread_id: fork_id, resume: "거절")
  end

  @doc "결제 승인 그래프: plan → approve(interrupt) → finish."
  def approval_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:plan, &__MODULE__.plan/2)
    |> ElGraph.add_node(:approve, &__MODULE__.approve/2)
    |> ElGraph.add_node(:finish, &__MODULE__.finish/2)
    |> ElGraph.add_edge(:plan, :approve)
    |> ElGraph.add_edge(:approve, :finish)
    |> ElGraph.compile(entry: :plan)
  end

  def plan(_state, _ctx), do: %{}

  def approve(_state, ctx) do
    %{result: ElGraph.Ctx.interrupt(ctx, %{action: "결제", amount: 50_000, to: "SHOP"})}
  end

  def finish(_state, _ctx), do: %{result: :done}
end
