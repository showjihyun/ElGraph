defmodule ElGraph.A2ATest do
  use ExUnit.Case, async: true

  alias ElGraph.A2A

  describe "to_task_state/1 — Task 생명주기 매핑 (SPEC §6)" do
    test "{:ok, state} maps to COMPLETED with the final state" do
      assert %{state: "completed", result: %{answer: "done"}} =
               A2A.to_task_state({:ok, %{answer: "done"}})
    end

    test "{:error, reason} maps to FAILED with the error" do
      assert %{state: "failed", error: {:node_crashed, :a, _}} =
               A2A.to_task_state({:error, {:node_crashed, :a, :boom}})
    end

    test "{:interrupted, info} maps to INPUT_REQUIRED with the payload" do
      assert %{state: "input-required", payload: %{question: "name?"}} =
               A2A.to_task_state({:interrupted, %{node: :ask, payload: %{question: "name?"}}})
    end
  end

  describe "agent_card/1 — Agent Card 생성" do
    test "builds a card with capabilities and skills from tools" do
      card =
        A2A.agent_card(
          name: "docs-agent",
          description: "ElGraph 문서 Q&A",
          tools: [ElGraph.TestActions.Search]
        )

      assert %{
               "name" => "docs-agent",
               "description" => "ElGraph 문서 Q&A",
               "capabilities" => %{"streaming" => true},
               "skills" => [%{"id" => "web_search", "description" => _}]
             } = card
    end

    test "an agent with no tools still produces a valid card" do
      card = A2A.agent_card(name: "summarizer", description: "요약", tools: [])
      assert %{"name" => "summarizer", "skills" => []} = card
    end
  end

  describe "message_to_input/1 — A2A Message → 시그널 입력" do
    test "extracts text parts into a question input" do
      message = %{
        "role" => "user",
        "parts" => [%{"text" => "ElGraph가 뭐야?"}, %{"text" => " 자세히."}]
      }

      assert %{question: "ElGraph가 뭐야? 자세히."} = A2A.message_to_input(message)
    end

    test "ignores non-text parts" do
      message = %{"role" => "user", "parts" => [%{"text" => "hi"}, %{"file" => %{}}]}
      assert %{question: "hi"} = A2A.message_to_input(message)
    end
  end
end
