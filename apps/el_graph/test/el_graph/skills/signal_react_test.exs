defmodule ElGraph.Skills.SignalReActTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, LLM, Signal}
  alias ElGraph.Test.ScriptedLLM

  defmodule QAAgent do
    use ElGraph.Skills.SignalReAct,
      route: "question.*",
      input_key: :question,
      tools: [ElGraph.TestActions.Search],
      system: "질문에 답하라",
      reply_tag: :qa_reply
  end

  defmodule TransformAgent do
    use ElGraph.Skills.SignalReAct,
      route: "text.submitted",
      input_key: :text,
      tools: [],
      system: "요약하라",
      reply_tag: :summary
  end

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {pid, {ScriptedLLM, pid}}
  end

  describe "Skill 추출 (SPEC §5 M4)" do
    test "routes a matching signal through react and replies with answer + usage" do
      {_pid, llm} = scripted([LLM.assistant("정답")])

      agent =
        start_supervised!({QAAgent, llm: llm, id: "qa", owner: self(), reply_to: self()})

      Agent.send_signal(agent, %Signal{type: "question.asked", data: %{question: "뭐야?"}})

      assert_receive {:qa_reply, %{answer: "정답", usage: %{input_tokens: _, output_tokens: _}}},
                     2_000
    end

    test "ignores signals whose type does not match the route" do
      {_pid, llm} = scripted([])

      agent =
        start_supervised!({QAAgent, llm: llm, id: "qa2", owner: self(), reply_to: self()})

      Agent.send_signal(agent, %Signal{type: "other.event", data: %{question: "x"}})

      refute_receive {:qa_reply, _payload}, 100
    end

    test "drives a full tool-call loop using the configured tools" do
      {pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "q"})]),
          LLM.assistant("툴 결과로 답함")
        ])

      agent =
        start_supervised!({QAAgent, llm: llm, id: "qa3", owner: self(), reply_to: self()})

      Agent.send_signal(agent, %Signal{type: "question.asked", data: %{question: "검색"}})

      assert_receive {:qa_reply, %{answer: "툴 결과로 답함"}}, 2_000
      # 두 번째 LLM 호출이 실제 툴 결과를 받았다.
      assert [_first, second] = ScriptedLLM.calls(pid)
      assert Enum.any?(second.messages, &match?(%{role: :tool}, &1))
    end

    test "a tool-less Skill does a single transform turn" do
      {pid, llm} = scripted([LLM.assistant("요약본")])

      agent =
        start_supervised!({TransformAgent, llm: llm, id: "tr", owner: self(), reply_to: self()})

      Agent.send_signal(agent, %Signal{type: "text.submitted", data: %{text: "긴 글"}})

      assert_receive {:summary, %{answer: "요약본"}}, 2_000
      assert [_one] = ScriptedLLM.calls(pid)
    end
  end
end
