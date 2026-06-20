# Adding a tool

A tool is an `ElGraph.Action` — one schema generates **both** parameter validation and the LLM
tool-spec, so you never hand-write JSON schema.

## Define an action

```elixir
defmodule MyApp.WebSearch do
  use ElGraph.Action,
    name: "web_search",
    description: "Search the web",
    schema: [query: [type: :string, required: true]]

  @impl true
  def run(%{query: q}, _ctx) do
    {:ok, %{results: ["3 results for #{q}"]}}
  end
end
```

- `schema:` uses `NimbleOptions` syntax. Arguments are validated **before** `run/2` runs.
- `run/2` returns `{:ok, result}` or `{:error, reason}`; the result is sent back to the model as the
  tool message content.

## Use it in a ReAct agent

```elixir
alias ElGraph.{LLM, Presets}

llm = {ElGraph.LLM.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")}
agent = Presets.react(llm, [MyApp.WebSearch])

ElGraph.invoke(agent, %{messages: [LLM.user("search for elixir agents")]})
```

The ReAct loop calls the LLM, runs any requested tools, feeds results back, and repeats until the
model answers. **Tool failures are recoverable**: an unknown tool name (model hallucination) or a
failed argument validation comes back as an `"error: ..."` tool message instead of crashing the
run — only an LLM call failure raises (pair it with a `retry:` policy).

### Useful `react/3` options

`Presets.react(llm, tools, opts)` accepts `:system` (system prompt), `:guardrails`
(`[input: [...], output: [...]]`), `:rate_limiter`, and `:budget` (token ceiling that interrupts).

## No API key? Test with ScriptedLLM

Run the full loop with zero credentials using `ElGraph.Test.ScriptedLLM` — see the
[getting-started notebook](https://github.com/showjihyun/ElGraph/blob/main/notebooks/getting_started.en.livemd).
