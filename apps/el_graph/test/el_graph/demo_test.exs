defmodule ElGraph.DemoTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Demo, LLM}
  alias ElGraph.Test.ScriptedLLM

  describe "DocsSearch (도그푸딩 툴)" do
    test "finds matching lines in project docs with file:line prefixes" do
      assert {:ok, %{results: results}} = Demo.DocsSearch.execute(%{query: "Pregel"}, %{})

      assert results != []
      assert Enum.any?(results, &String.starts_with?(&1, "SPEC.md:"))
    end

    test "caps results and is case-insensitive" do
      assert {:ok, %{results: results}} = Demo.DocsSearch.execute(%{query: "elgraph"}, %{})

      assert length(results) <= 20
      assert results != []
    end

    test "multi-word queries match lines containing any word, best matches first" do
      # 도그푸딩 발견(2026-06-13): 전체 문자열 부분일치는 멀티워드 질의에서 0건이 된다.
      assert {:ok, %{results: results}} =
               Demo.DocsSearch.execute(%{query: "체크포인트 보존 정책 옵션"}, %{})

      assert results != []

      # 가장 많은 단어가 겹치는 줄이 앞에 온다 — 보존 정책(keep:) 줄이 상위에 있어야 한다.
      assert results |> Enum.take(5) |> Enum.any?(&String.contains?(&1, "keep"))
    end
  end

  describe "Demo supervision tree (SPEC §8 M3 도그푸딩)" do
    test "answers a question end-to-end through the tree (scripted LLM)" do
      {:ok, llm_pid} =
        ScriptedLLM.start_link([
          LLM.assistant(nil, [LLM.tool_call("c1", "docs_search", %{"query" => "Pregel"})]),
          LLM.assistant("superstep 루프로 실행됩니다")
        ])

      start_supervised!({Demo, llm: {ScriptedLLM, llm_pid}, reply_to: self()})

      assert :ok = Demo.ask("ElGraph의 실행 모델이 뭐야?")
      assert_receive {:demo_answer, %{answer: "superstep 루프로 실행됩니다"}}, 2_000

      # LLM의 두 번째 호출이 실제 문서 검색 결과를 받았다 — 툴이 진짜 실행됐다.
      assert [_first, second] = ScriptedLLM.calls(llm_pid)
      assert Enum.any?(second.messages, &match?(%{role: :tool, content: %{results: [_ | _]}}, &1))
    end

    test "the agent ignores unrelated signal types" do
      {:ok, llm_pid} = ScriptedLLM.start_link([])
      start_supervised!({Demo, llm: {ScriptedLLM, llm_pid}, reply_to: self()})

      ElGraph.Agent.send_signal(
        ElGraph.Agent.via(Demo.AgentRegistry, "docs"),
        %ElGraph.Signal{type: "noise.event"}
      )

      refute_receive {:demo_answer, _answer}, 100
    end
  end
end
