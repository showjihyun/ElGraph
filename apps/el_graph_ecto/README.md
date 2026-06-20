# ElGraphEcto

**Postgres durable checkpointer + Store for [ElGraph](https://hex.pm/packages/el_graph)** (Ecto/Postgrex).

ElGraph's core ships BEAM-built-in checkpointers (ETS/DETS/Mnesia, zero external infra). This
package adds **Postgres-backed** durability so a thread can resume across VM/node restarts, plus
a Postgres `ElGraph.Store` for long-lived `ElGraph.Memory` facts.

## Install

```elixir
def deps do
  [
    {:el_graph, "~> 0.3"},
    {:el_graph_ecto, "~> 0.4"}
  ]
end
```

## Usage

```elixir
# Checkpointer — durable thread state across restarts
cp = {ElGraph.Checkpointer.Postgres, ElGraph.Checkpointer.Postgres.config(MyApp.Repo)}
ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

# Store — durable long-term Memory facts
store = {ElGraph.Store.Postgres, ElGraph.Store.Postgres.config(MyApp.Repo)}
mem = ElGraph.Memory.new(store)
```

Run the migrations `ElGraphEcto.Migration` (checkpoints/writes) and `ElGraphEcto.StoreMigration`
(store) against your repo. Retention is configurable per adapter: `config(repo, keep: {:last, n})`.

## Security

Checkpoints/store values are serialized with `:erlang.term_to_binary/1`; non-serializable terms
(pid/ref/port/local fn) are rejected before write. **Reads use `binary_to_term(_, [:safe])`** —
a tampered database cannot inject new atoms or functions (atom-exhaustion / RCE surface).

---

Part of the [ElGraph umbrella](https://github.com/showjihyun/ElGraph). MIT.
