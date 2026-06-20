# Choosing a checkpointer

A checkpointer persists graph state so a thread can pause/resume, recover after a crash, and
time-travel. Pass one to `invoke`/`resume` — **without it, execution is stateless** (no durability,
no HITL).

```elixir
ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")
```

## Backends

| Backend | Module | Infra | Use when |
|---|---|---|---|
| ETS | `ElGraph.Checkpointer.ETS` | none (in-memory) | dev, tests, ephemeral single-node |
| DETS | `ElGraph.Checkpointer.Dets` | none (disk file) | single-node disk persistence |
| Mnesia | `ElGraph.Checkpointer.Mnesia` | none (BEAM) | distributable (`disc_copies`) |
| Postgres | `ElGraph.Checkpointer.Postgres` | Postgres | durable, shared, cross-restart (`el_graph_ecto`) |
| Valkey/Redis | `ElGraph.Checkpointer.Redis` | Valkey/Redis | fast durable (`el_graph_redis`) |

The first three ship with the core (zero external infra). Postgres/Valkey live in sibling packages.

```elixir
# BEAM built-in, zero infra
cp = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(owner_pid)}

# Postgres (add {:el_graph_ecto, "~> 0.4"})
cp = {ElGraph.Checkpointer.Postgres, ElGraph.Checkpointer.Postgres.config(MyApp.Repo)}
```

## Durability modes

`:durability` controls *when* checkpoints are written:

- `:sync` (default) — persist after every step. Safest.
- `:async` — a linked writer process persists off the hot path. Fastest steady-state.
- `:exit` — persist only at the end and at interrupts. Least I/O.

```elixir
ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1", durability: :async)
```

## Retention

All backends support `keep: {:last, n}` — keep only the most recent `n` checkpoints per thread:

```elixir
ElGraph.Checkpointer.Postgres.config(MyApp.Repo, keep: {:last, 50})
```

## Security

The Postgres/Valkey adapters serialize with `term_to_binary` and read back with
`binary_to_term(_, [:safe])`, so a tampered database cannot inject new atoms or code. Still treat
the database as trusted infrastructure (restrict write access).
