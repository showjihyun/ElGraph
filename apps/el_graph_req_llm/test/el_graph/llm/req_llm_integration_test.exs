defmodule ElGraph.LLM.ReqLLMIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Presets, Secrets}
  alias ElGraph.LLM.ReqLLM, as: Adapter

  # 코어 el_graph의 test/support는 앱 경계를 넘지 못하므로 로컬 검색 Action을 정의한다.
  defmodule Search do
    use ElGraph.Action,
      name: "web_search",
      description: "Search the web",
      schema: [query: [type: :string, required: true]]

    @impl true
    def run(%{query: q}, _ctx), do: {:ok, %{results: ["#{q}:result"]}}
  end

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    # req_llm 실연동 시 Finch 풀 등 앱이 떠 있어야 한다.
    _ = Application.ensure_all_started(:req_llm)
    :ok
  end

  # "openai:gpt-4o"로 OpenAI 키를 재사용한다(다른 프로바이더면 모델 스펙만 바꾸면 됨).
  defp config, do: [model: "openai:gpt-4o", api_key: Secrets.fetch!(:openai_api_key)]

  test "chat round-trips against a real provider via ReqLLM" do
    assert {:ok, %{message: %{role: :assistant, content: content}, usage: usage}} =
             Adapter.chat(config(), [LLM.user("What is 2+2? Reply with the number only.")], [])

    assert content =~ "4"
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0
  end

  test "the ReAct preset completes a real tool-call loop via ReqLLM" do
    llm = {Adapter, config()}

    graph =
      Presets.react(llm, [Search],
        system:
          "You MUST call the web_search tool to answer any question. " <>
            "After receiving the tool result, summarize it in one short sentence."
      )

    assert {:ok, %{messages: messages, usage: usage}} =
             ElGraph.invoke(graph, %{messages: [LLM.user("Search for: elixir langgraph")]})

    # 전체 루프: 툴 호출 → 툴 결과 → 최종 assistant 답변
    assert Enum.any?(messages, &match?(%{role: :tool, name: "web_search"}, &1))
    assert %{role: :assistant, content: content} = List.last(messages)
    assert is_binary(content) and content != ""
    assert usage.input_tokens > 0
  end
end
