defmodule ElGraph.Presets.BudgetTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Presets}
  alias ElGraph.Checkpointer.ETS
  alias ElGraph.TestActions.Search
  alias ElGraph.Test.ScriptedLLM

  setup do
    pid = start_supervised!(ETS)
    %{checkpointer: {ETS, ETS.config(pid)}}
  end

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {pid, {ScriptedLLM, pid}}
  end

  defp expensive(message, tokens) do
    half = div(tokens, 2)
    {:ok, %{message: message, usage: %{input_tokens: half, output_tokens: tokens - half}}}
  end

  defp tool_call_turn(tokens) do
    expensive(LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "q"})]), tokens)
  end

  describe "비용 가드 (SPEC §4, 부록 A-4)" do
    test "usage is accumulated across turns into the :usage channel" do
      {_pid, llm} = scripted([tool_call_turn(100), expensive(LLM.assistant("done"), 60)])
      graph = Presets.react(llm, [Search])

      assert {:ok, %{usage: %{input_tokens: 80, output_tokens: 80}}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})
    end

    test "an exhausted budget interrupts before the next LLM call", %{checkpointer: cp} do
      {pid, llm} = scripted([tool_call_turn(100), expensive(LLM.assistant("done"), 10)])
      graph = Presets.react(llm, [Search], budget: [tokens: 50])

      assert {:interrupted,
              %{
                node: :agent,
                payload: %{
                  type: :budget_exceeded,
                  budget: 50,
                  usage: %{input_tokens: 50, output_tokens: 50}
                }
              }} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]},
                 checkpointer: cp,
                 thread_id: "t1"
               )

      # 두 번째 LLM 호출은 일어나지 않았다 — 인터럽트는 호출 이전이다.
      assert [_only_one_call] = ScriptedLLM.calls(pid)
    end

    test "resume with a raised budget continues the run", %{checkpointer: cp} do
      {_pid, llm} = scripted([tool_call_turn(100), expensive(LLM.assistant("done"), 10)])
      graph = Presets.react(llm, [Search], budget: [tokens: 50])

      {:interrupted, _info} =
        ElGraph.invoke(graph, %{messages: [LLM.user("go")]}, checkpointer: cp, thread_id: "t1")

      assert {:ok, %{messages: messages, budget: 1_000}} =
               ElGraph.resume(graph, checkpointer: cp, thread_id: "t1", resume: 1_000)

      assert %{role: :assistant, content: "done"} = List.last(messages)
    end

    test "the budget check is pre-call: the first call always runs" do
      {_pid, llm} = scripted([expensive(LLM.assistant("cheap answer"), 100)])
      graph = Presets.react(llm, [Search], budget: [tokens: 50])

      # usage 0에서 시작하므로 첫 호출은 허용된다 (한도는 다음 호출 전에 걸린다).
      assert {:ok, %{messages: messages}} = ElGraph.invoke(graph, %{messages: [LLM.user("go")]})
      assert %{content: "cheap answer"} = List.last(messages)
    end
  end
end
