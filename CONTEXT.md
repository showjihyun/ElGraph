# ElGraph — Context

Domain language for ElGraph, a graph-first agent framework on the BEAM. The full
design lives in `docs/SPEC.md`; this file captures the **vocabulary** — the
opinionated names for concepts, so code and conversation stay consistent. Terms
are added lazily as they're sharpened (e.g. during architecture reviews).

## Language — LLM layer

**LLM**:
The provider-neutral behaviour the core talks to (`chat/3`, optional
`stream_chat/3`). It is the public **seam** between graph nodes and any model
backend; the core knows nothing else about models.
_Avoid_: model client, API client (when you mean this behaviour).

**Provider**:
A concrete adapter for one vendor's API (OpenAI, Anthropic, Gemini) expressed as
mapping callbacks behind `ElGraph.LLM.Driver`. A Provider supplies only what
genuinely varies — request shape, response parse, and chunk→delta/usage
decoding — not transport or accumulation.
_Avoid_: backend, vendor, integration (when you mean the adapter module).

**Driver**:
The shared machine (`ElGraph.LLM.Driver`) that runs a Provider's mapping:
HTTP execution, SSE framing, live delta emission, response folding, usage
merging, and telemetry. One implementation; every Provider delegates to it.
The Provider behaviour (`ElGraph.LLM.Provider`) is the seam the Driver drives.
_Avoid_: HTTP client (undersells it — it folds and instruments too), runner
(reserved for graph execution, see `ElGraph.Runner`).

**delta**:
One incremental streaming event emitted to `on_delta`:
`{:token, text}` | `{:tool_call_start, id, name}` | `{:tool_call_delta, id, frag}`
| `{:tool_call_end, id}`. The grammar is **lossless** — the final response is
folded from the delta stream, so a Provider decodes each SSE chunk into deltas
once (no separate accumulation parser).
_Avoid_: chunk, token (a token is one kind of delta), event (overloaded with
the executor's stream events).

**usage**:
Token accounting for one model call: `%{input_tokens, output_tokens}`. Carried
on the response and on `[:el_graph, :llm, :chat]` telemetry; not part of the
delta stream (a Provider's `decode_usage/1` returns partial usage the Driver
merges).
_Avoid_: tokens, cost, metering.

## Language — Node context

**Ctx**:
The execution context every node receives as its second argument (`(state, ctx)`,
fixed by SPEC §3.2). Its **public interface** is small: the fields
`thread_id`/`step`/`node`/`assigns` plus the functions `emit/2`, `interrupt/2`,
`cancelled?/1`, `memo/3`. That is the whole surface a node author must learn.
_Avoid_: state (that's the node's first argument), env, metadata.

**Ctx.Internal**:
The executor's per-invocation wiring (event sink, cancel flag, task cache,
interrupt counter, fan-out node key, concurrency limit), quarantined behind the
opaque `ctx.private` field. Nodes never touch it; the public Ctx functions read
from it. It can evolve without changing the public `Ctx` type.
_Avoid_: private (the field name), guts, opaque (describe the role, not the keyword).

## Example dialogue

> **Dev:** The OpenAI adapter re-parses the stream twice — once to emit, once to
> accumulate. Can the Provider just emit?
>
> **Architect:** The **Driver** owns accumulation now. The **Provider** decodes
> each chunk into **deltas** once; the Driver emits them live *and* folds them
> into the final response. The Provider also returns partial **usage** per
> chunk, which the Driver merges — usage isn't a delta.
>
> **Dev:** So a new vendor is just request shape, response parse, and decode?
>
> **Architect:** Right — a thin **Provider** behind the **Driver**. The public
> **LLM** behaviour callers see doesn't change.
