# ElGraphRedis

**Valkey/Redis durable checkpointer + Store for [ElGraph](https://hex.pm/packages/el_graph)** (Redix).

ElGraph's core ships BEAM-built-in checkpointers (ETS/DETS/Mnesia, zero external infra). This
package adds a **Valkey/Redis-backed** checkpointer for fast durable thread state, plus a
Valkey/Redis `ElGraph.Store` for long-lived `ElGraph.Memory` facts. **Valkey and Redis both
work** — only universal RESP commands (`GET/SET/DEL/ZADD/ZRANGE/HSET/HGETALL`) are used.

## Install

```elixir
def deps do
  [
    {:el_graph, "~> 0.3"},
    {:el_graph_redis, "~> 0.4"}
  ]
end
```

## Usage

```elixir
{:ok, conn} = Redix.start_link(host: "localhost", port: 6379, name: :my_redix)

# Checkpointer — durable thread state (enable RDB/AOF for persistence across restarts)
cp = {ElGraph.Checkpointer.Redis, ElGraph.Checkpointer.Redis.config(:my_redix)}
ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")

# Store — durable long-term Memory facts
store = {ElGraph.Store.Redis, ElGraph.Store.Redis.config(:my_redix)}
mem = ElGraph.Memory.new(store)
```

Retention is configurable: `config(conn, keep: {:last, n})`. Key prefix via `prefix:`.

## Security

Values are serialized with `:erlang.term_to_binary/1`; non-serializable terms are rejected
before write. **Reads use `binary_to_term(_, [:safe])`** — a tampered store cannot inject new
atoms or functions (atom-exhaustion / RCE surface).

---

Part of the [ElGraph umbrella](https://github.com/showjihyun/ElGraph). MIT.
