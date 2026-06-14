# ElGraph

[한국어](README.md) | **English**

> **A graph-first agent framework running on the BEAM (Elixir/OTP).**
> Delivers LangGraph-style durable execution, human-in-the-loop, and checkpointing
> with zero Python dependency — and adds a real-time observability UI (ElTrace) on top.

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

## ✨ Highlights

- **Graph core** — state channels/reducers, conditional edges, parallel fan-out, subgraphs. Only one runtime dependency: `:telemetry`.
- **Durable execution** — checkpoint → resume. A partially failed parallel step preserves the work that succeeded, avoiding duplicate LLM calls. Swappable backends: **ETS** (in-memory) · **DETS·Mnesia** (BEAM built-in, zero-infra disk persistence) · **Postgres** · **Valkey/Redis** — all support `keep: {:last, n}` retention.
- **Human-in-the-loop (HITL)** — pause before or inside a node, take a human's answer, and continue from that exact point.
- **Time-travel** — fork a new thread from any past checkpoint. The original is preserved.
- **Agent runtime** — GenServer agents, a signal bus, a ReAct preset, LLM/MCP adapters, cost guards.
- **Real-time observability UI (ElTrace)** — watch a thread's lifecycle as a browser timeline; approve/reject and "branch here" with a click.

> Why Elixir? The things LangGraph had to *reimplement as a library* in Python (durable
> execution, parallel isolation, streaming bus, distributed workers) are runtime built-ins
> on the BEAM — same capabilities with less code and stronger guarantees.
> Details: [`docs/elixir-vs-python-comparison.md`](docs/elixir-vs-python-comparison.md).

---

## 🚀 Quick start

### 1. Prerequisites

- **Elixir 1.18+** / **Erlang/OTP 27+** (developed & verified on Elixir 1.20 / OTP 28)
- New to the toolchain? → [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) (includes a Windows `scoop` walkthrough)

Verify your install:

```bash
elixir --version    # Elixir 1.18 or newer is fine
```

### 2. Clone + deps + tests

This repo is an **umbrella project** — you drive both apps from the root.

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

### 4. Launch the observability UI (recommended — most intuitive)

```bash
cd apps/el_trace
mix phx.server
```

Open **http://localhost:4000** and you'll see an example thread waiting for approval.
Follow the timeline in real time and **approve/reject** it, or **branch here** at a specific
step to spin up a "what if I'd rejected?" scenario as a new thread.

> The first browser run builds the JavaScript assets once:
> `mix esbuild el_trace` (or `mix phx.server` handles it automatically in dev).

---

## ⚖️ LangGraph vs ElGraph

> In one line: **what LangGraph had to "reimplement as a library" in Python is a runtime
> built-in on the BEAM.** So you get the same capabilities with *less code, less
> infrastructure, and stronger guarantees*.

An agent orchestrator is ultimately a problem of **"many concurrent I/O waits + state
management + failure recovery."** That is exactly the problem the BEAM (the Erlang/Elixir
runtime) has been solving in telecom switches for 30 years.

| Dimension | LangGraph (Python) | **ElGraph (Elixir/BEAM)** | ElGraph advantage |
|---|---|---|---|
| **Concurrency** | asyncio event loop / GIL pins CPU to one core | millions of lightweight processes, all cores used automatically | ✅ tens of thousands of concurrent agents with **zero design change** |
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

### So, when should you pick ElGraph?

- ✅ When you need **10k+ concurrent agents / long-lived ("always alive") agents / self-healing**
- ✅ When **real-time observability & human-in-the-loop UI** is part of the product (ElTrace, no extra infra)
- ✅ When you need to reach **distribution with minimal infra** (no broker/worker-pool ops)
- ✅ When **minimizing supply chain / image size** matters in production

Conversely, if fast ML experimentation, running local models directly, or staying close to
the Python ecosystem is your core need, LangGraph is the more comfortable choice.

> Full dimension-by-dimension comparison (concurrency, correctness, fault recovery,
> streaming, distribution, deployment): [`docs/elixir-vs-python-comparison.md`](docs/elixir-vs-python-comparison.md).

## 📦 Project structure

```
ElGraph/                  # umbrella root (run mix test / mix format here)
├─ apps/
│  ├─ el_graph/           # core runtime — graph, checkpoints, agents, LLM/MCP (zero deps)
│  ├─ el_trace/           # observability UI — Phoenix/LiveView (depends on el_graph)
│  ├─ el_graph_ecto/      # durable checkpointer — Postgres (Ecto)
│  └─ el_graph_redis/     # durable checkpointer — Valkey/Redis (Redix)
├─ examples/
│  └─ observed_agent/     # example of consuming el_graph + el_trace as dependencies
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
loop. Adapters: `ElGraph.LLM.OpenAI` / `.Anthropic` / `.Gemini`, plus `ElGraph.Test.ScriptedLLM` for tests.

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
