defmodule ElGraph.LLM.OpenAIIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Presets, Secrets}
  alias ElGraph.LLM.OpenAI
  alias ElGraph.TestActions.Search

  @moduletag :integration
  @moduletag timeout: 60_000

  defp config, do: [api_key: Secrets.fetch!(:openai_api_key)]

  test "chat round-trips against the real OpenAI API" do
    assert {:ok, %{message: %{role: :assistant, content: content}, usage: usage}} =
             OpenAI.chat(config(), [LLM.user("What is 2+2? Reply with the number only.")], [])

    assert content =~ "4"
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0
  end

  test "the ReAct preset completes a real tool-call loop" do
    llm = {OpenAI, config()}

    graph =
      Presets.react(llm, [Search],
        system:
          "You MUST call the web_search tool to answer any question. " <>
            "After receiving the tool result, summarize it in one short sentence."
      )

    assert {:ok, %{messages: messages, usage: usage}} =
             ElGraph.invoke(graph, %{messages: [LLM.user("Search for: elixir langgraph")]})

    # 전체 루프 검증: 툴 호출 → 툴 결과 → 최종 assistant 답변
    assert Enum.any?(messages, &match?(%{role: :tool, name: "web_search"}, &1))
    assert %{role: :assistant, content: content} = List.last(messages)
    assert is_binary(content) and content != ""
    assert usage.input_tokens > 0
  end
end
