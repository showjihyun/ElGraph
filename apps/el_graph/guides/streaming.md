# Streaming

Stream LLM tokens to the user in real time. Native SSE streaming is implemented for **OpenAI,
Anthropic, and Gemini**.

## Stream from a node

```elixir
alias ElGraph.LLM

def my_node(state, ctx) do
  {:ok, %{message: msg}} = LLM.stream_to_ctx(llm, state.messages, [], ctx)
  %{messages: [msg]}
end
```

`stream_to_ctx/4` calls the adapter's `stream_chat/3` and emits each delta to the node's event sink
via `Ctx.emit/2`. Deltas are:

- `{:token, text}`
- `{:tool_call_start, id, name}` · `{:tool_call_delta, id, fragment}` · `{:tool_call_end, id}`

It returns the same accumulated `{:ok, response}` as `chat/3`, so the rest of your node is unchanged.

## Receive the deltas

Pass `event_sink: self()` (or any pid) to `invoke`; deltas arrive as `{:el_graph_event, _}`
messages you can `receive`. The same channel carries lifecycle events (node start/stop, interrupts).

## Check support first, fall back to `chat/3`

Not every adapter streams. Guard with `stream_supported?/1`:

```elixir
if LLM.stream_supported?(llm) do
  LLM.stream_to_ctx(llm, messages, [], ctx)
else
  {mod, cfg} = llm
  mod.chat(cfg, messages, [])
end
```

`ElGraph.LLM.ReqLLM` is non-streaming, so `stream_supported?/1` returns `false` for it — see the
[ReqLLM guide](req-llm.md).
