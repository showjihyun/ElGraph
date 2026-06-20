# ElGraph benchmarks

Runnable [Benchee](https://hex.pm/packages/benchee) microbenchmarks for the core executor.
They measure **orchestrator runtime overhead** (no LLM/IO) so the numbers reflect ElGraph's
own machinery, not model latency.

```sh
cd apps/el_graph
mix run bench/concurrency_scaling.exs    # N concurrent agents: 100 → 1k → 10k
mix run bench/superstep_throughput.exs   # sequential chain vs parallel fan-out
mix run bench/durability_modes.exs       # :sync vs :async vs :exit vs no checkpointer
mix run bench/input_projection.exs       # input: [...] projection on/off
mix run bench/concurrency_tuning.exs     # sweep max_concurrency for a fixed agent batch

BENCH_TIME=1 mix run bench/<file>.exs    # quick smoke (shorter sampling)
```

These are honest measurements, not marketing numbers — run them on your own hardware. They
exist to make the README's concurrency/scaling claims *checkable* rather than asserted. A reference
run (with machine specs and the key findings) is in [`RESULTS.md`](RESULTS.md).

## What each one shows

| Bench | Question it answers |
|---|---|
| `concurrency_scaling` | Does running 100 → 1k → 10k agents concurrently stay roughly linear? (BEAM lightweight processes, all cores) |
| `superstep_throughput` | Cost of an 8-step sequential chain vs an 8-branch parallel fan-out in one invoke. |
| `durability_modes` | Latency/memory cost of each checkpoint persistence mode vs no checkpointer. |
| `input_projection` | Whether `input: [keys]` (`Map.take` projection) reduces copy cost into parallel nodes. |
| `concurrency_tuning` | What `max_concurrency` runs a fixed agent batch fastest? (launching all at once oversubscribes the schedulers — ~6.8× slower at 10k). |

## Honest caveats

- For **I/O-bound agent loops** (real LLM calls) the orchestrator overhead measured here is
  dwarfed by model latency — the BEAM edge is about fault isolation, durability, and holding
  many long-lived sessions, not raw throughput on tiny pure-CPU nodes.
- `input_projection` typically shows only a **marginal** win for in-process fan-out (nodes
  share the heap); the benefit grows with payload size and cross-process copying.
- `:async` durability adds a writer-process hop that can *cost* more than `:sync` on tiny
  workloads — it pays off when per-step persistence latency is the bottleneck.
