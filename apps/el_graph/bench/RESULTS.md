# Benchmark results (snapshot)

A reference run of the [`bench/`](.) suite. **Numbers are machine-specific** — run them on your own
hardware (`mix run bench/<file>.exs`). These measure the **orchestrator runtime overhead only**
(pure-CPU nodes, no LLM/IO), so they reflect ElGraph's own machinery, not model latency.

## Environment

| | |
|---|---|
| Date | 2026-06-20 |
| CPU | 12 cores |
| RAM | 31.6 GB |
| Elixir / OTP | 1.20.1 / 28 |
| OS | Windows 11 (dev laptop, single node) |

> Caveat: a Windows dev laptop is not a production Linux server, and real agent workloads are
> I/O-bound (LLM calls of 100s of ms–seconds) — so the microsecond-scale overhead here is
> negligible end-to-end. The point is the *shape* of the curves, not absolute numbers.

## 1. Concurrency scaling

`concurrency_scaling.exs` — run N independent agents (each a 2-superstep graph), bounded at
`max_concurrency = cores * 4` (see the tuning finding below).

| Agents | Total time | Per-agent | Memory | Mem/agent |
|---|---|---|---|---|
| 100 | 1.27 ms | ~12.7 µs | 125 KB | ~1.25 KB |
| 1,000 | 12.3 ms | ~12.3 µs | 1.15 MB | ~1.15 KB |
| 10,000 | 132 ms | ~13.2 µs | 11.5 MB | ~1.15 KB |

**Per-agent cost is essentially flat across 100×, and memory is linear (~1.15 KB/agent).** 10k
durable-capable agents cost ~132 ms and ~11.5 MB.

## 2. Superstep throughput

`superstep_throughput.exs` — a single `invoke` of an 8-step graph.

| Graph | Average | Throughput | Memory |
|---|---|---|---|
| Sequential 8-node chain | 19.0 µs | 52.5K ips | 18.2 KB |
| Parallel 8-branch fan-out | 87.9 µs | 11.4K ips | 20.2 KB |

For **trivial** nodes the parallel fan-out is 4.6× *slower* — process spawn/merge overhead
dominates. Parallelism pays off only when node work is substantial (LLM/IO), not for pure-CPU toys.

## 3. Durability mode overhead

`durability_modes.exs` — an 8-step graph with an ETS checkpointer.

| Mode | Average | vs baseline |
|---|---|---|
| No checkpointer | 20.9 µs | — |
| `:exit` (final only) | 23.7 µs | 1.13× (+2.8 µs) |
| `:sync` (per-step) | 50.0 µs | 2.40× (+29 µs) |
| `:async` (writer process) | 68.0 µs | 3.26× (+47 µs) |

Durability is cheap: `:exit` is nearly free, `:sync` adds ~3.6 µs per step. `:async` is *slower*
than `:sync` here — its writer-process hop costs more than it saves for fast in-memory ETS and
light per-step work; it pays off when persistence latency (Postgres/Redis) is the bottleneck.
Memory differences were negligible (< 3.2 KB).

## 4. Input projection

`input_projection.exs` — 50 × 2 KB blobs in state, 8 parallel workers needing only `:n`.

| | Average | Memory |
|---|---|---|
| `input: [:n]` projection | 182 µs | 58.80 KB |
| no projection (full state) | 186 µs | 58.79 KB |

Marginal (~1.02×, memory equal) for in-process fan-out — nodes share the heap, so there's no
cross-process copy to save. The benefit grows with larger payloads and cross-process copying.

## Finding: cap `max_concurrency`, don't launch everything at once

`concurrency_tuning.exs` — the same 10k-agent batch, sweeping the concurrency cap on 12 cores:

| max_concurrency | 10k-agent time | vs best |
|---|---|---|
| **cores × 4 (48)** | **97.6 ms** | best |
| cores (12) | 98.0 ms | 1.00× |
| cores × 16 (192) | 107 ms | 1.10× |
| cores × 50 (600) | 151 ms | 1.55× |
| cores × 100 (1200) | 198 ms | 2.03× |
| unbounded (10000) | 668 ms | **6.85× slower** |

Launching all 10k tasks at once **oversubscribes the schedulers and is ~6.8× slower** than a sane
bound. Around `cores * 4` is optimal here, giving ~9.8 µs/agent — *better* per-agent than a smaller
unbounded batch. This is why `concurrency_scaling.exs` bounds concurrency by default; it's a usage
guideline, not a framework limitation.

## Takeaways (honest)

1. **Orchestrator overhead is microseconds/agent and flat** — irrelevant next to real LLM latency
   (100s of ms–seconds). ElGraph's value is durability, isolation, and statefulness, not raw speed.
2. **It scales near-linearly when you don't oversubscribe** — memory ~1.15 KB/agent; 10k agents in
   ~132 ms. The "10k+ agents" claim holds for feasibility and memory; throughput needs a sane
   `max_concurrency`.
3. **Durability is cheap** — µs-scale per step. "Durable execution is too expensive to turn on" is
   not borne out by the data.
4. **Parallelism and input projection are situational** — both can *cost* more for trivial nodes;
   they win with heavier per-node work / larger payloads.
