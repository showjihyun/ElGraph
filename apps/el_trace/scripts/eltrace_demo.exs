# ElTrace 시연: Langfuse가 못 보여준 #1·#2를 체크포인트로 보여준다
#   mix run scripts/eltrace_demo.exs
#
# 도그푸딩 세션 7 대비: Langfuse는 멈춘 invoke를 "짧은 trace"로만 보여줬고(왜 멈췄는지 없음),
# invoke↔resume을 나란히 놓을 뿐이었다. ElTrace는 체크포인트로 thread 생애 + 인터럽트를 명시.

alias ElGraph.Checkpointer.ETS
alias ElTrace.Timeline

{:ok, cp_pid} = ETS.start_link()
cp = {ETS, ETS.config(cp_pid)}
tid = "eltrace-demo"

# 사람 승인이 필요한 노드: 결제 전 확인 (동적 인터럽트 + payload)
defmodule Demo.Approval do
  alias ElGraph.{Ctx, LLM}

  def plan(_state, _ctx), do: %{messages: [LLM.user("100만원 송금 요청")]}

  def approve(state, ctx) do
    answer = Ctx.interrupt(ctx, %{action: "송금", amount: 1_000_000, to: "ACME"})
    %{messages: state.messages ++ [LLM.user("승인: #{answer}")]}
  end

  def execute(_state, _ctx), do: %{result: :sent}
end

graph =
  ElGraph.new()
  |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
  |> ElGraph.state(:result)
  |> ElGraph.add_node(:plan, &Demo.Approval.plan/2)
  |> ElGraph.add_node(:approve, &Demo.Approval.approve/2)
  |> ElGraph.add_node(:execute, &Demo.Approval.execute/2)
  |> ElGraph.add_edge(:plan, :approve)
  |> ElGraph.add_edge(:approve, :execute)
  |> ElGraph.compile(entry: :plan)

IO.puts("=== 1차 invoke (사람 승인 대기에서 멈춤) ===")
{:interrupted, info} = ElGraph.invoke(graph, %{}, checkpointer: cp, thread_id: tid)
IO.puts("멈춤 — node=#{info.node}, payload=#{inspect(info.payload)}")

IO.puts("\n[ElTrace 타임라인 — 멈춘 시점]")
cp |> Timeline.build(tid) |> Timeline.render() |> IO.puts()

IO.puts("\n=== 사람이 승인 → resume ===")
{:ok, final} = ElGraph.resume(graph, checkpointer: cp, thread_id: tid, resume: "OK")
IO.puts("완료 — result=#{inspect(final.result)}")

IO.puts("\n[ElTrace 타임라인 — thread 전체 생애 (#1 인터럽트 + #2 invoke→resume)]")
cp |> Timeline.build(tid) |> Timeline.render() |> IO.puts()

# #4 time-travel: 승인 직전(step 1)으로 되감아 "거절했다면?"을 새 thread로 가본다.
IO.puts("\n=== #4 time-travel: step 1(승인 대기)로 되감아 분기 ===")
fork = "#{tid}-rejected"

case ElTrace.Replay.from(cp, tid, 1, graph, as: fork) do
  {:interrupted, finfo} ->
    IO.puts("분기 thread '#{fork}'도 같은 지점에서 멈춤 — payload=#{inspect(finfo.payload)}")
    {:ok, _} = ElGraph.resume(graph, checkpointer: cp, thread_id: fork, resume: "거절")
    IO.puts("이번엔 '거절'로 재개")

  {:ok, _} ->
    IO.puts("(분기가 인터럽트 없이 진행)")
end

IO.puts("\n[원래 thread '#{tid}' — 보존됨]")
cp |> Timeline.build(tid) |> Timeline.render() |> IO.puts()

IO.puts("\n[분기 thread '#{fork}' — step 1에서 갈라진 별도 생애]")
cp |> Timeline.build(fork) |> Timeline.render() |> IO.puts()
