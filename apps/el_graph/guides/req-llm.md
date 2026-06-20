# Using ReqLLM (1000+ models)

`ElGraph.LLM.ReqLLM` wraps [ReqLLM](https://hex.pm/packages/req_llm) so a single adapter reaches
~21 providers / 1000+ models (OpenAI, Anthropic, Google, Groq, xAI, OpenRouter, …).

## Install

It lives in a separate app so the core stays dependency-light:

```elixir
def deps do
  [
    {:el_graph, "~> 0.3"},
    {:el_graph_req_llm, github: "showjihyun/ElGraph", sparse: "apps/el_graph_req_llm"}
  ]
end
```

## Use it

```elixir
llm = {ElGraph.LLM.ReqLLM, model: "openai:gpt-4o"}
# or "anthropic:claude-haiku-4-5", "google:gemini-2.0-flash", "groq:llama-3.3-70b", ...

agent = ElGraph.Presets.react(llm, [MyApp.SearchAction])
```

- `:model` (required) — a ReqLLM model spec string.
- `:api_key` — optional; otherwise ReqLLM loads it from app config / the standard `*_API_KEY` env var.
- `:req_llm_options` — extra options passed straight to `ReqLLM.generate_text/3`.

Tool execution stays with ElGraph's Action machine — the adapter only sends tool specs to the model
and maps returned tool calls back into ElGraph messages.

## Streaming

This adapter is **non-streaming** (`chat/3` only). `ElGraph.LLM.stream_supported?/1` returns `false`
for it, so guard before streaming and fall back to `chat/3`. For token-level SSE streaming use the
native `ElGraph.LLM.{OpenAI, Anthropic, Gemini}` adapters — see the [Streaming guide](streaming.md).
