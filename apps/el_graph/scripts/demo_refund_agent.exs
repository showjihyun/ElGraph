# ElGraph demo — "refund-approval agent" (a hypothetical scenario, no API key).
#   mix run scripts/demo_refund_agent.exs
#
# Shows the core ElGraph loop end to end: build a graph, run it until a
# human-in-the-loop pause, resume with the human's decision, then *time-travel*
# — fork the paused checkpoint and explore the other decision, original preserved.

alias ElGraph.Ctx

defmodule RefundDemo do
  @moduledoc false

  def check_policy(_state, _ctx),
    do: %{policy: "full refund within 30 days", messages: ["policy: eligible"]}

  def approve(state, ctx) do
    decision =
      Ctx.interrupt(ctx, %{question: "Approve $#{state.amount} refund?", policy: state.policy})

    %{decision: decision}
  end

  def execute(%{decision: "approve", amount: a}, _ctx),
    do: %{result: "approved — $#{a} refunded, arrives in 3 business days"}

  def execute(_state, _ctx),
    do: %{result: "rejected — customer notified with the reason"}
end

graph =
  ElGraph.new()
  |> ElGraph.state(:amount, default: 0)
  |> ElGraph.state(:policy, default: nil)
  |> ElGraph.state(:decision, default: nil)
  |> ElGraph.state(:result, default: nil)
  |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
  |> ElGraph.add_node(:check_policy, &RefundDemo.check_policy/2)
  |> ElGraph.add_node(:approve, &RefundDemo.approve/2)
  |> ElGraph.add_node(:execute, &RefundDemo.execute/2)
  |> ElGraph.add_edge(:check_policy, :approve)
  |> ElGraph.add_edge(:approve, :execute)
  |> ElGraph.compile(entry: :check_policy)

{:ok, cp_pid} = ElGraph.Checkpointer.ETS.start_link()
cfg = ElGraph.Checkpointer.ETS.config(cp_pid)
cp = {ElGraph.Checkpointer.ETS, cfg}

p = fn s -> IO.puts(s) end

p.("")
p.("  ElGraph — refund-approval agent")
p.("  graph:  check_policy --> approve(HITL) --> execute")
p.("")
p.("  [1] invoke  (thread \"req-001\", amount $50,000)")

{:interrupted, info} =
  ElGraph.invoke(graph, %{amount: 50_000}, checkpointer: cp, thread_id: "req-001")

{:ok, interrupt_cp} = ElGraph.Checkpointer.ETS.get(cfg, "req-001", :latest)

p.("      paused at @#{info.node}  (durable checkpoint saved)")
p.("      => #{inspect(info.payload)}")
p.("")
p.("  [2] resume  with \"approve\"")
{:ok, approved} = ElGraph.resume(graph, checkpointer: cp, thread_id: "req-001", resume: "approve")
p.("      => #{approved.result}")
p.("")
p.("  [3] time-travel  — fork the paused point, decide \"reject\" instead")
forked = %{interrupt_cp | thread_id: "req-001-alt"}
:ok = ElGraph.Checkpointer.ETS.put(cfg, forked)

{:ok, rejected} =
  ElGraph.resume(graph, checkpointer: cp, thread_id: "req-001-alt", resume: "reject")

p.("      => #{rejected.result}")
p.("")
p.("  both timelines coexist — the approved run was never lost:")
p.("      req-001      ->  #{approved.result}")
p.("      req-001-alt  ->  #{rejected.result}")
p.("")
