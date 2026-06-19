# ElGraph

[한국어](README.ko.md) | **English**

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fshowjihyun%2FElGraph%2Fmain%2Fnotebooks%2Fgetting_started.livemd)

> **A graph-first agent framework running on the BEAM (Elixir/OTP).**
> Delivers LangGraph-style durable execution, human-in-the-loop, and checkpointing
> with zero Python dependency — and adds a real-time observability UI (ElTrace) on top.

![ElGraph — graph, human-in-the-loop, time-travel](docs/assets/elgraph-demo.gif)

*▶ A refund-approval agent: a graph runs, **pauses for human approval** (HITL), resumes with the
decision, then **time-travels** — forks the paused checkpoint to try the other decision, the
original run preserved. No API key: `mix run apps/el_graph/scripts/demo_refund_agent.exs`*

![ElTrace — real-time observability, HITL, time-travel](docs/assets/eltrace-demo.gif)

*🎬 **ElTrace** — watch agent runs live, **approve/reject** at interrupts (HITL), and **"branch here"**
from any past step (time-travel). See it yourself: `cd apps/el_trace && mix phx.server` → http://localhost:4000*

Declare an LLM agent as **state channels + nodes + edges**, and ElGraph runs it on
checkpoints. It can pause for human approval (HITL), resume from the last point after a
crash, and rewind to any past step to safely explore "what if I'd gone differently?".

```
user input ─▶ [run graph] ─▶ checkpoint after every step
                  │
                  ├─ interrupt → human approves/rejects → resume
                  └─ fork from a past step → explore "what-if" scenarios
```

---

## 🤔 Why ElGraph? (3-line summary)

1. **Declare your LLM agent as a graph** → ElGraph runs it on top of checkpoints.
2. **Pause (HITL), rewind (time-travel), resume after a crash** — durable execution is the default.
3. **No Python, no external infra** — the BEAM runtime gives you concurrency, fault recovery, and real-time for free (the only core runtime dependency is `:telemetry`).

> One line: *what LangGraph had to laboriously reimplement as a library in Python is a runtime built-in on the BEAM.*

## ✨ Highlights

- **Graph core** — state channels/reducers, conditional edges, parallel fan-out, subgraphs. Only one runtime dependency: `:telemetry`.
- **Durable execution** — checkpoint → resume. A partially failed parallel step preserves the work that succeeded, and `Ctx.memo/3` **task memoization** skips re-running LLM/tool calls on resume or retry. Swappable backends: **ETS** (in-memory) · **DETS·Mnesia** (BEAM built-in, zero-infra disk persistence) · **Postgres** · **Valkey/Redis** — all support `keep: {:last, n}` retention.
- **Human-in-the-loop (HITL)** — pause before or inside a node, take a human's answer, and continue from that exact point.
- **Time-travel** — fork a new thread from any past checkpoint. The original is preserved.
- **Agent runtime** — GenServer agents, a signal bus, a ReAct preset, LLM/MCP adapters, cost guards, guardrails/PII, and **structured-output retry** (feed validation errors back on failure).
- **Memory** — 3 scopes (episodic/semantic/procedural) with temporal truth, **point-in-time queries** (`fact_at`), **conflict resolution**, and semantic recall. Swappable `Memory.Backend` (native/**Mem0**/**Zep**); the Store persists to ETS/Valkey/Postgres.
- **Distribution (BEAM-native)** — `:pg` signal bus with **at-least-once idempotent delivery** (Signal id/Dedup, absorbs netsplit redelivery), multi-node `:peer` verification, libcluster delegated to the host.
- **Interop (bidirectional MCP)** — expose ElGraph Actions as an **MCP server** (HTTP `/mcp` + stdio; tools/resources/prompts) plus an **MCP client** (Streamable HTTP, bidirectional sampling/elicitation/roots). A2A HTTP and AG-UI SSE are provided too.
- **Real-time observability UI (ElTrace)** — watch a thread's lifecycle as a browser timeline; approve/reject and "branch here" with a click. Telemetry (invoke/node/llm.chat spans + retry/interrupt/checkpoint/bus/sensor events) → OTel bridge → Langfuse.

> Why Elixir? The things LangGraph had to *reimplement as a library* in Python (durable
> execution, parallel isolation, streaming bus, distributed workers) are runtime built-ins
> on the BEAM — same capabilities with less code and stronger guarantees.
> Details: [`docs/elixir-vs-python-comparison.md`](docs/elixir-vs-python-comparison.md).

---

## 🚀 Quick start

### 1. Prerequisites

- **Elixir 1.18+** / **Erlang/OTP 27+** (developed & verified on Elixir 1.20 / OTP 28)
- Install (pick one):
  - **macOS**: `brew install elixir`
  - **Linux · macOS (version-managed)**: [asdf](https://asdf-vm.com) (`asdf plugin add erlang && asdf plugin add elixir`)
  - **Windows**: `scoop install erlang elixir` — details in [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md)

Verify your install:

```bash
elixir --version    # Elixir 1.18 or newer is fine
```

### 2. Install

**A) Add it to your project as a dependency** — `mix.exs`:

```elixir
def deps do
  [
    # Before the Hex release — from the git subdirectory:
    {:el_graph, github: "showjihyun/ElGraph", sparse: "apps/el_graph"}
    # After the Hex release:
    # {:el_graph, "~> 0.3"}
  ]
end
```

> Both git and Hex are public, so **installing needs no auth** — `mix hex.user auth` is a publisher-only step.

The core `el_graph` alone is a headless (server-less) agent runtime. The durable checkpointers
(Postgres/Redis), the observability UI (ElTrace), and the A2A/AG-UI HTTP server are separate
sibling apps (see *Project structure* below).

**B) Clone ElGraph itself to explore or develop it** — this repo is an **umbrella project**:

```bash
git clone https://github.com/showjihyun/ElGraph.git
cd ElGraph
mix deps.get        # install dependencies
mix test            # full suite (all async) — green means your env is good
```

> On Windows, if `mix` isn't found, put it on PATH (see ENVIRONMENT.md):
> ```powershell
> $env:Path = "$env:USERPROFILE\scoop\shims;$env:USERPROFILE\scoop\apps\elixir\current\bin;$env:Path"
> ```

### 3. Your first graph in 30 seconds

```bash
iex -S mix
```

```elixir
graph =
  ElGraph.new()
  |> ElGraph.state(:n, default: 0)
  |> ElGraph.add_node(:double, fn %{n: n}, _ctx -> %{n: n * 2} end)
  |> ElGraph.add_node(:inc, fn %{n: n}, _ctx -> %{n: n + 1} end)
  |> ElGraph.add_edge(:double, :inc)
  |> ElGraph.compile(entry: :double)

ElGraph.invoke(graph, %{n: 10})
#=> {:ok, %{n: 21}}
```

A node takes `(state, ctx)` and returns a **partial state-update map**. That's the whole model.

**Your first agent — no API key.** `ElGraph.Test.ScriptedLLM` returns canned responses, so you
can run the full ReAct agent loop with zero credentials:

```elixir
alias ElGraph.{LLM, Presets}
alias ElGraph.Test.ScriptedLLM

{:ok, pid} = ScriptedLLM.start_link([LLM.assistant("Hi! How can I help?")])
graph = Presets.react({ScriptedLLM, pid}, [])

ElGraph.invoke(graph, %{messages: [LLM.user("hello")]})
#=> {:ok, %{messages: [%{role: :user, ...}, %{role: :assistant, content: "Hi! How can I help?"}], ...}}
```

Swap in a real adapter when you're ready — `ElGraph.LLM.OpenAI` / `.Anthropic` / `.Gemini`.

### 4. Launch the observability UI (recommended — most intuitive)

```bash
cd apps/el_trace
mix phx.server
```

Open **http://localhost:4000** and you'll see an example thread waiting for approval.
Follow the timeline in real time and **approve/reject** it, or **branch here** at a specific
step to spin up a "what if I'd rejected?" scenario as a new thread.

![ElTrace timeline — approve/reject and branch-here at an interrupt](docs/assets/eltrace-hero.png)

> The first browser run builds the JavaScript assets once:
> `mix esbuild el_trace` (or `mix phx.server` handles it automatically in dev).

---

## ⚖️ LangChain · LangGraph vs ElGraph

> In one line: **what LangGraph had to "reimplement as a library" in Python is a runtime
> built-in on the BEAM.** So you get the same capabilities with *less code, less
> infrastructure, and stronger guarantees*.

### At a glance — LangChain · LangGraph · ElGraph

> **They live at different layers**: **LangChain** is an *assembly library* that wires prompts, tools, and RAG; **LangGraph** is the *graph state-machine* layer on top that handles state and durable execution (which is why it was split out). **ElGraph's direct counterpart is LangGraph** — and because it runs on the BEAM, it folds in what LangGraph leans on external systems for (real-time UI, distribution, self-healing).

| | **LangChain** | **LangGraph** | **ElGraph** |
|---|---|---|---|
| In a word | LLM "assembly" library | Python graph state-machine | **BEAM** graph state-machine |
| Core role | prompt·tool·RAG chains | durable exec·HITL·checkpoints | 〃 **+ real-time observability·distribution** |
| Execution model | chain/DAG (shallow state) | graph + channels/reducers | graph + channels/reducers |
| Runtime | Python (asyncio/GIL) | Python (asyncio/GIL) | BEAM (lightweight processes·preemption·built-in distribution) |
| Durable exec·resume | ✖ (out of scope) | ✔ reimplemented as a library | ✔ **one with the runtime** |
| HITL · time-travel | ✖ | ✔ HITL / partial rewind | ✔ HITL **+ fork from a past point** |
| Fault isolation·self-healing | app code + external infra | app code + external infra | **Supervisor·process isolation (language standard)** |
| Concurrency | GIL-bound | GIL-bound | **all cores·isolated lightweight processes** |
| Dependencies·deploy | many transitive deps | many transitive deps | **effectively zero** core deps (`:telemetry` only)·single release |
| Real-time UI | bolt-on | bolt-on | **same LiveView model** (ElTrace·zero infra) |

An agent orchestrator is ultimately a problem of **"many concurrent I/O waits + state
management + failure recovery."** That is exactly the problem the BEAM (the Erlang/Elixir
runtime) has been solving in telecom switches for 30 years.

| Dimension | LangGraph (Python) | **ElGraph (Elixir/BEAM)** | ElGraph advantage |
|---|---|---|---|
| **Concurrency** | asyncio event loop / GIL pins CPU to one core | millions of lightweight processes, all cores used automatically | ◐ strong for isolation/statefulness; pure I/O-bound fan-out is fine on asyncio too |
| **API shape** | dual `invoke`/`ainvoke` API (colored functions) | preemptive scheduling → **a single API** | ✅ the "sync/async function color" problem simply doesn't exist |
| **Fault isolation** | `try/except` at every boundary; a miss propagates everywhere | process isolation + supervisor trees (crash-only) | ✅ one agent's death can't take down the others |
| **Self-healing** | needs **external infra** (K8s restarts, Celery retries) | supervisor restarts + checkpoint recovery are **language standard** | ✅ long-lived agent recovery lives inside the framework |
| **Durable exec / checkpoints** | reimplemented as a library | runtime and checkpoints are one piece | ✅ partially failed parallel steps keep successes → no duplicate LLM calls |
| **State safety** | mutable dicts (docs warn you to "copy before use") | everything immutable | ✅ parallel-branch data races are **impossible by language** |
| **Real-time UI** | FastAPI + SSE/WebSocket wired up separately | same message model as Phoenix LiveView | ✅ agent events → browser with **zero extra infra** (ElTrace is the proof) |
| **Distribution / scale-out** | requires Redis/RabbitMQ/Kafka + Celery | distributed Erlang + `:pg` built in | ✅ handoffs across node boundaries are nearly identical code |
| **Deploy / supply chain** | dozens of transitive deps, hundreds of MB images | core has **zero external deps**, `mix release` single binary | ✅ drastically smaller supply-chain surface and image size |

### Honestly — where LangGraph is better

ML/model-adjacent work favors Python: provider SDKs, tokenizers, eval tooling, and local
models (PyTorch) ship Python-first, and the community/tutorials/talent pool are far larger.
ElGraph **routes around this via HTTP APIs + MCP** — an orchestrator never needs to run the
model itself, so the workaround is structurally sound. (Embeddings/tokenization are absorbed
through the API's `usage` response or MCP tools.)

**"Python brain, Elixir nervous system."** The pragmatic 2026 pattern isn't either/or — it's a
division of labor: keep the model (inference, embeddings, fine-tuning) on Python/hosted APIs,
and let ElGraph be the *durable, concurrent, observable orchestration layer* that calls them
(over MCP, A2A, HTTP). ElGraph does not try to replace the ML stack.

**On BEAM concurrency, honestly.** The tables above show what the BEAM *can* do (tens of
thousands concurrent, all cores) — but it's fair to say *when* that pays off. For workloads
that are pure network-wait (a simple request→LLM→response), the BEAM edge is small: Python
asyncio handles thousands of concurrent calls just fine, and the real bottleneck is usually
model/GPU capacity, not the orchestrator runtime. Where the BEAM *decisively* wins is
elsewhere — **fault isolation** (one conversation crashing while thousands continue),
**preemptive scheduling** (a runaway node can't starve the others), **stateful long-lived
sessions** (the same model that lets Phoenix hold 100k+ concurrent connections per server),
and **durable execution + distribution**. The real advantage is **isolation, durability, and
statefulness** — not "more concurrent calls."

### So, when should you pick ElGraph?

- ✅ When you need **10k+ concurrent agents / long-lived ("always alive") agents / self-healing**
- ✅ When **real-time observability & human-in-the-loop UI** is part of the product (ElTrace, no extra infra)
- ✅ When you need to reach **distribution with minimal infra** (no broker/worker-pool ops)
- ✅ When **minimizing supply chain / image size** matters in production

Conversely, if fast ML experimentation, running local models directly, or staying close to
the Python ecosystem is your core need, LangGraph is the more comfortable choice.

> Full dimension-by-dimension comparison (concurrency, correctness, fault recovery,
> streaming, distribution, deployment): [`docs/elixir-vs-python-comparison.md`](docs/elixir-vs-python-comparison.md).

### Where it sits in the Elixir ecosystem

There are good agent tools on the BEAM too. ElGraph's seat is the *graph executor*:

- **Jido** (mature, ~1.7k★) — immutable functional agents + signals/FSM. It has persistence, checkpoints, and HITL too, but as *whole-agent snapshots* (hibernate/thaw), not per-step versioned checkpoints with pending writes, and it isn't a conditional/cyclic graph executor.
- **sagents** (built on brainlid/langchain) — strong HITL approvals, but execution is a *fixed linear pipeline* and checkpoints are terminal-point save/restore (no mid-graph resume).
- **Oban Pro Workflows** — genuine durable dynamic fan-out/fan-in, but *paid, acyclic (DAG)*, with no graph-state checkpoints or HITL.

ElGraph's combination: **per-step versioned checkpoints + pending writes + interrupt HITL + dynamic fan-out over a conditional/cyclic graph**, in one runtime, open-core. The moat is *the bundle*, not any single axis.

## 📦 Project structure

```
ElGraph/                  # umbrella root (run mix test / mix format here)
├─ apps/
│  ├─ el_graph/           # core runtime — graph, checkpoints, agents, LLM/MCP (zero deps)
│  ├─ el_graph_web/       # A2A (JSON-RPC) · AG-UI (SSE) HTTP server — Plug/Bandit
│  ├─ el_trace/           # observability UI — Phoenix/LiveView (depends on el_graph)
│  ├─ el_graph_ecto/      # durable checkpointer — Postgres (Ecto)
│  ├─ el_graph_redis/     # durable checkpointer — Valkey/Redis (Redix)
│  ├─ el_graph_req_llm/   # LLM adapter — ~21 providers via ReqLLM
│  └─ el_graph_otel/      # OTel SDK bridge — telemetry → OTel/Langfuse
├─ examples/
│  └─ observed_agent/     # example of consuming el_graph + el_trace as dependencies
├─ notebooks/             # Livebook examples (run instantly in the browser)
│  └─ getting_started.livemd
├─ config/                # shared config (secrets.exs is gitignored)
├─ docker-compose.yml     # Postgres/Valkey for DB-backend tests
└─ docs/                  # full design spec, environment, testing conventions
```

Durable checkpointers are **swappable adapters** implementing the core `ElGraph.Checkpointer`
behaviour. ETS is in-memory (fast, but lost on restart); the rest resume threads across restarts
and node replacement:

```elixir
# BEAM built-in — zero external infra (shipped in core el_graph)
cp = {ElGraph.Checkpointer.Dets,   ElGraph.Checkpointer.Dets.config(pid)}    # single file
cp = {ElGraph.Checkpointer.Mnesia, ElGraph.Checkpointer.Mnesia.config(pid)}  # distributable (disc_copies)
# External DBs (optional sibling apps)
cp = {ElGraph.Checkpointer.Postgres, ElGraph.Checkpointer.Postgres.config(MyApp.Repo)}
cp = {ElGraph.Checkpointer.Redis,    ElGraph.Checkpointer.Redis.config(:my_redix)}

ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")
```

Postgres needs a migration: `mix el_graph.ecto.gen.migration -r MyApp.Repo` then `mix ecto.migrate`.

- Use **`el_graph`** alone for a headless (server-less) agent runtime.
- **`el_trace`** adds a real-time observe/intervene UI. General-purpose tracing (spans/tokens)
  is delegated to tools like Langfuse; ElTrace focuses on the causality only the ElGraph
  checkpoints know (interrupts, thread lifecycle, time-travel).

---

## 📖 A little more — 5-minute tour

### ReAct agent (one-line preset)

```elixir
llm = {ElGraph.LLM.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")}
graph = ElGraph.Presets.react(llm, [MyApp.SearchAction], budget: [tokens: 100_000])

{:ok, %{messages: messages}} =
  ElGraph.invoke(graph, %{messages: [ElGraph.LLM.user("search for elixir")]})
```

When the LLM calls a tool, it runs automatically and feeds the result back to the model in a
loop. Adapters: `ElGraph.LLM.OpenAI` / `.Anthropic` / `.Gemini` (+ `.ReqLLM` — [ReqLLM](https://hex.pm/packages/req_llm) → ~21 providers / 1000+ models, via the `el_graph_req_llm` app), plus `ElGraph.Test.ScriptedLLM` for tests.

### Durable execution + human approval (HITL)

```elixir
cp = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(pid)}

# pause where approval is needed
{:interrupted, %{node: :approve, payload: payload}} =
  ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

# inject the human's answer and resume — from the pause point, without re-running finished nodes
{:ok, final} = ElGraph.resume(graph, checkpointer: cp, thread_id: "t1", resume: "approved")
```

### Time-travel fork (ElTrace)

```elixir
ElTrace.observe("t1", graph, cp)                 # register with the UI
{:ok, fork_id, _} = ElTrace.fork("t1", 1, as: "t1-rejected")   # branch at step 1
ElGraph.resume(graph, checkpointer: cp, thread_id: fork_id, resume: "rejected")  # original is preserved
```

See the full working example in [`examples/observed_agent`](examples/observed_agent).

---

## 📚 Docs

| Doc | Contents |
|---|---|
| [`docs/SPEC.md`](docs/SPEC.md) | Full design spec, milestones, review history |
| [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) | Dev environment setup (Windows/scoop) |
| [`docs/TDD-SPEC.md`](docs/TDD-SPEC.md) | Testing conventions (TDD, all async) |
| [`docs/elixir-vs-python-comparison.md`](docs/elixir-vs-python-comparison.md) | vs. LangGraph |
| [`docs/ecosystem-review.md`](docs/ecosystem-review.md) | Ecosystem review & adoption proposals (Elixir/OSS framework analysis, in Korean) |
| [`docs/DOGFOODING.md`](docs/DOGFOODING.md) | Real-usage observation log |

---

## 🛠 Development

```bash
mix test                       # full (el_graph + el_trace)
mix test --only integration    # real API calls (requires config/secrets.exs)
mix format                     # required before commit

# run a single app's tests from that app's directory
cd apps/el_trace && mix test test/el_trace/sessions_test.exs
```

Conventions: TDD (red → green → refactor), all tests `async: true`. Details in [`docs/TDD-SPEC.md`](docs/TDD-SPEC.md).

If you need real LLM keys, copy the template and fill it in (do not commit — it's gitignored):

```bash
cp config/secrets.example.exs config/secrets.exs
```

---

## Status

The M1 (core) through M5 (multi-agent / distribution) cores are implemented and verified, and
the observability track is working through the ElTrace LiveView (timeline visualization,
approve/reject, branch-here). Milestone details: [SPEC §8](docs/SPEC.md).

## License

[MIT](LICENSE)
