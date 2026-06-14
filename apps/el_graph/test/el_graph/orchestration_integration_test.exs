defmodule ElGraph.OrchestrationIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Orchestration, Secrets}
  alias ElGraph.LLM.OpenAI

  @moduletag :integration
  @moduletag timeout: 60_000

  defp config, do: [api_key: Secrets.fetch!(:openai_api_key)]

  defmodule Workers do
    def research(_state, _ctx),
      do: %{messages: [LLM.assistant("research: Elixir is a BEAM language")]}

    def write(_state, _ctx), do: %{messages: [LLM.assistant("write: Elixir runs on the BEAM.")]}
  end

  defp workers do
    [
      %{name: :researcher, description: "gathers facts about a topic", run: &Workers.research/2},
      %{name: :writer, description: "writes the final one-sentence answer", run: &Workers.write/2}
    ]
  end

  test "the supervisor template completes against the real OpenAI API" do
    graph =
      Orchestration.supervisor({OpenAI, config()}, workers(),
        system:
          "Delegate to researcher first, then writer, then reply DONE. " <>
            "Reply with the worker name only, or DONE."
      )

    assert {:ok, %{messages: messages}} =
             ElGraph.invoke(graph, %{messages: [LLM.user("Write one sentence about Elixir.")]})

    assert is_list(messages) and messages != []
  end
end
