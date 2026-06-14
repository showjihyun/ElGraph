defmodule ElGraph.Skills.HandoffTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Signal}
  alias ElGraph.Signal.Bus
  alias ElGraph.Test.ScriptedLLM

  defmodule Researcher do
    use ElGraph.Skills.SignalReAct,
      route: "question.*",
      input_key: :question,
      tools: [],
      system: "조사하라",
      reply_tag: :research_done
  end

  defmodule Summarizer do
    use ElGraph.Skills.SignalReAct,
      route: "research.done",
      input_key: :answer,
      tools: [],
      system: "요약하라",
      reply_tag: :summary_done
  end

  setup do
    bus = :"bus_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus})
    %{bus: bus}
  end

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {ScriptedLLM, pid}
  end

  describe "handoff via :emit (SPEC §6)" do
    test "an agent emits its result to the bus as a signal", %{bus: bus} do
      {:ok, llm_pid} = ScriptedLLM.start_link([LLM.assistant("조사 결과")])

      agent =
        start_supervised!(
          {Researcher, llm: {ScriptedLLM, llm_pid}, id: "r", emit: {bus, "research.done"}}
        )

      parent = self()
      Bus.subscribe(bus, "research.done", fn s -> send(parent, {:emitted, s}) end)

      ElGraph.Agent.send_signal(agent, %Signal{type: "question.asked", data: %{question: "뭐야?"}})

      assert_receive {:emitted, %Signal{type: "research.done", data: %{answer: "조사 결과"}}}, 2_000
    end

    test "two agents form a pipeline through the bus (Researcher -> Summarizer)", %{bus: bus} do
      researcher_llm = scripted([LLM.assistant("긴 조사 결과")])
      summarizer_llm = scripted([LLM.assistant("짧은 요약")])

      # Researcher: question.* 구독 → 결과를 research.done으로 emit
      start_supervised!(
        {Researcher,
         llm: researcher_llm,
         id: "res",
         subscribe: {bus, "question.*"},
         emit: {bus, "research.done"}},
        id: :res
      )

      # Summarizer: research.done 구독 → 결과를 reply_to로
      start_supervised!(
        {Summarizer,
         llm: summarizer_llm, id: "sum", subscribe: {bus, "research.done"}, reply_to: self()},
        id: :sum
      )

      # 파이프라인 시동: 질문 하나 발행.
      Bus.publish(bus, %Signal{type: "question.asked", data: %{question: "ElGraph?"}})

      # Researcher → (research.done) → Summarizer → reply_to
      assert_receive {:summary_done, %{answer: "짧은 요약"}}, 3_000

      # Summarizer가 받은 입력은 Researcher의 출력이었다.
      assert [call] = ScriptedLLM.calls(elem(summarizer_llm, 1))
      assert Enum.any?(call.messages, &(&1.content == "긴 조사 결과"))
    end
  end
end
