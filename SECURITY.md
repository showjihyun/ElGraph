# Security Policy

## Supported versions

ElGraph is pre-1.0; security fixes land on the latest `0.x` release of each package.

| Package | Supported |
|---|---|
| `el_graph` (core) | latest `0.x` |
| `el_graph_web` / `el_graph_ecto` / `el_graph_redis` | latest `0.x` |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via **[GitHub Security Advisories](https://github.com/showjihyun/ElGraph/security/advisories/new)**
(the "Report a vulnerability" button on the repository's *Security* tab). We aim to acknowledge
within a few days and will coordinate a fix and a disclosure timeline with you.

## Security posture

ElGraph is built to fail safe by default:

- **HTTP auth is fail-closed** — `ElGraphWeb` rejects requests with `401` unless `api_keys` is
  configured; disabling auth requires an explicit `api_keys: :public`.
- **Safe deserialization** — the Postgres/Valkey checkpointer + store adapters read with
  `:erlang.binary_to_term(_, [:safe])`, blocking atom-exhaustion / code-injection from a tampered
  database.
- **Request body limits** — A2A/AG-UI/MCP routers cap request body size (`413` over the limit).
- **Sandboxed code execution** — `ElGraph.Sandbox` runs untrusted code out-of-process
  (Command/Docker backends); the Docker backend defaults to `--network=none --read-only`.

### Operator responsibilities

- Configure `api_keys` (or explicitly `:public`) on `ElGraphWeb` endpoints.
- Treat your checkpointer/store database as trusted infrastructure (restrict write access).
- Configure guardrails (`ElGraph.Guardrail`) for untrusted input, and prefer the Docker sandbox
  backend for untrusted code.
