# Structured-fact Memory and the semantic-recall Backend are separate seams

**Status:** accepted

`ElGraph.Memory` (3-scope structured facts — episodic/semantic/procedural, plus
point-in-time truth, temporal queries, and conflict resolution) is built directly
on the `ElGraph.Store` behaviour. `ElGraph.Memory.Backend` is a **separate**,
deliberately narrow behaviour (`remember`/`recall`) for swappable semantic recall:
`Native` (core embedder over Store), `Mem0` (REST), `Zep` (temporal knowledge
graph). The structured-fact depth is **not** delegated to Backend — it is the
differentiator and stays in core.

## Considered options

- **Push `on_conflict`/upsert/temporal into the Backend interface** so external
  services (e.g. Zep's temporal KG) participate in fact semantics.
- **Keep them separate (chosen).** Backend stays the narrow remember/recall seam;
  structured facts stay on `Store` in `Memory`.

## Why

The narrow remember/recall surface is exactly what external memory services do
well; widening the Backend interface to carry scopes/temporal/conflict would force
every adapter to implement (or stub) semantics that `Mem0`/`Native` can't
meaningfully provide, and would couple the structured-fact layer to the recall
seam. Three adapters already justify the seam as-is, and `Native` wrapping
`Memory.recall_relevant` is the standard "default in-process adapter behind a
behaviour" pattern (cf. `Checkpointer.ETS` behind `Checkpointer`).

## Consequences

- Semantic recall has two surfaces by design: `Memory.recall_relevant/4` (the core
  embedder implementation, which the `Native` backend wraps) and `Backend.recall/4`
  (the swappable seam). `recall_relevant` is public API and `Native` depends on it.
- **Do not re-suggest** "the Backend seam is inverted/shallow" or folding structured
  facts into Backend, nor hiding `recall_relevant` behind the seam — the separation
  is intentional. Revisit only if structured facts must live in an external service.
