defmodule ElTrace.DevSeed do
  @moduledoc false
  # 개발 시드: 송금 승인 그래프를 인터럽트(사람 대기)까지 돌린 뒤 Sessions에 등록한다.
  # `mix phx.server`로 페이지를 열면 곧장 승인 대기 thread가 보이도록 한다.
  # eltrace_demo.exs의 시나리오를 lib로 옮긴 형태(데모용이므로 dev 전용).

  alias ElGraph.Checkpointer.ETS

  @thread "송금-승인-데모"

  def run do
    cp = {ETS, ETS.config(ElTrace.DevCheckpointer)}
    graph = transfer_graph()

    case ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: @thread) do
      {:interrupted, _info} -> ElTrace.observe(@thread, graph, cp)
      _ -> :ok
    end
  end

  defp transfer_graph do
    ElGraph.new()
    |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:plan, &__MODULE__.plan/2)
    |> ElGraph.add_node(:approve, &__MODULE__.approve/2)
    |> ElGraph.add_node(:execute, &__MODULE__.execute/2)
    |> ElGraph.add_edge(:plan, :approve)
    |> ElGraph.add_edge(:approve, :execute)
    |> ElGraph.compile(entry: :plan)
  end

  def plan(_state, _ctx), do: %{messages: [%{role: :user, content: "100만원 송금 요청"}]}

  def approve(state, ctx) do
    answer = ElGraph.Ctx.interrupt(ctx, %{action: "송금", amount: 1_000_000, to: "ACME"})
    %{messages: state.messages ++ [%{role: :user, content: "승인 결과: #{answer}"}]}
  end

  def execute(_state, _ctx), do: %{result: :sent}
end
