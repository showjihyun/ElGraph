# Human-in-the-loop (HITL)

ElGraph can pause a running graph, hand control to a human, and resume from the exact point —
because every step is checkpointed. A **checkpointer is required** for interrupts.

## Dynamic interrupt — pause inside a node

```elixir
alias ElGraph.Ctx

approve = fn state, ctx ->
  decision = Ctx.interrupt(ctx, %{question: "Approve $#{state.amount}?"})
  %{decision: decision}
end
```

`Ctx.interrupt/2` stops execution, saves a checkpoint, and makes `invoke` return `{:interrupted, info}`:

```elixir
cp = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(pid)}

{:interrupted, info} = ElGraph.invoke(graph, %{amount: 100}, checkpointer: cp, thread_id: "t1")
```

## Resume with the human's answer

```elixir
{:ok, result} = ElGraph.resume(graph, checkpointer: cp, thread_id: "t1", resume: "approved")
```

The injected value becomes the return of `Ctx.interrupt/2`. **Completed nodes are not re-run**, and
parallel siblings that finished before the interrupt keep their writes. Multiple interrupts in one
node are matched by call order.

## Static interrupt — pause before a node

```elixir
ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1", interrupt_before: [:risky_node])
```

## Time-travel (fork a past decision)

Copy a past checkpoint to a new `thread_id` and resume it with a different decision — the original
timeline is preserved, so both "what-if" branches coexist:

```elixir
{:ok, cp_struct} = ElGraph.Checkpointer.ETS.get(config, "t1", :latest)
forked = %{cp_struct | thread_id: "t1-rejected"}
:ok = ElGraph.Checkpointer.ETS.put(config, forked)

ElGraph.resume(graph, checkpointer: cp, thread_id: "t1-rejected", resume: "rejected")
```

This is what the ElTrace "branch here" button does (see `ElGraph.Executor.resume_from/3`).
