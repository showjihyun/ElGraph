# Contributing to ElGraph

Thanks for your interest! ElGraph is an Elixir **umbrella** project. This guide covers the essentials.

## Project layout

- `apps/el_graph` — core runtime (graph executor, checkpointers, agent runtime, LLM/MCP adapters). Only runtime dep: `:telemetry`.
- `apps/el_graph_web` — HTTP server (A2A / AG-UI / MCP over Plug/Bandit).
- `apps/el_graph_ecto` · `apps/el_graph_redis` — durable Postgres / Valkey checkpointer + store adapters.
- `apps/el_graph_otel` — OpenTelemetry bridge. `apps/el_trace` — real-time observability UI (Phoenix/LiveView).
- `docs/` — `SPEC.md` (design), `TDD-SPEC.md` (test rules), `ENVIRONMENT.md`, `DOGFOODING.md`.

## Development setup

Elixir `~> 1.18` / OTP 27+ (CI runs 1.20 / OTP 28). See `docs/ENVIRONMENT.md`.

```sh
mix deps.get
mix test            # from repo root: runs all apps
```

DB-backed adapter tests (Postgres/Valkey) auto-skip when no service is reachable. To run them,
`docker compose up` (Postgres + Valkey) or point `ELGRAPH_PG_*` / `ELGRAPH_REDIS_*` at your own.

## TDD is mandatory

All changes under `apps/*/lib/` follow [`docs/TDD-SPEC.md`](docs/TDD-SPEC.md):

1. **Red** — write a failing test first; run it and confirm it fails for the *intended* reason (not a compile error).
2. **Green** — minimum code to pass, then run the **full suite** (`mix test`).
3. **Refactor** — `mix format`, re-run. Never leave a step with failing tests.

Rules: all tests `async: true`, pattern-matching assertions, public API only, no `Process.sleep`.
Bug fixes start with a test that reproduces the bug.

## Before opening a PR

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix dialyzer        # 0 warnings expected
```

- Keep changes **surgical** — every changed line should trace to the stated goal.
- Update `CHANGELOG.md` (`[Unreleased]`) for user-visible changes.
- Reference any related issue, and fill in the PR template.

CI (`.github/workflows/ci.yml`) enforces format + test + dialyzer + integration.

## Reporting

Use the issue templates for bugs and feature requests. For **security** issues, see
[`SECURITY.md`](SECURITY.md) — please do **not** open a public issue.
