defmodule ElGraph.Demo.SummarizeAgentTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, LLM, Signal}
  alias ElGraph.Demo.SummarizeAgent
  alias ElGraph.Test.ScriptedLLM

  test "summarizes submitted text in a single LLM turn (no tool loop)" do
    {:ok, llm_pid} = ScriptedLLM.start_link([LLM.assistant("핵심 요약")])

    agent =
      start_supervised!(
        {SummarizeAgent, llm: {ScriptedLLM, llm_pid}, id: "sum", owner: self(), reply_to: self()}
      )

    Agent.send_signal(agent, %Signal{type: "text.submitted", data: %{text: "긴 본문..."}})

    assert_receive {:summary, %{answer: "핵심 요약"}}, 2_000

    # 툴이 없으므로 LLM은 정확히 한 번 호출된다.
    assert [_one_call] = ScriptedLLM.calls(llm_pid)
  end

  test "ignores unrelated signals" do
    {:ok, llm_pid} = ScriptedLLM.start_link([])

    agent =
      start_supervised!(
        {SummarizeAgent, llm: {ScriptedLLM, llm_pid}, id: "sum2", owner: self(), reply_to: self()}
      )

    Agent.send_signal(agent, %Signal{type: "question.asked", data: %{question: "x"}})

    refute_receive {:summary, _summary}, 100
  end
end
