defmodule ElGraph.Presets.RateLimitTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Presets, RateLimiter}
  alias ElGraph.TestActions.Search
  alias ElGraph.Test.ScriptedLLM

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {ScriptedLLM, pid}
  end

  describe "ReAct rate limiting (마찰 6)" do
    test "every LLM call passes through the rate limiter" do
      limiter = start_supervised!({RateLimiter, limit: 1})
      llm = scripted([LLM.assistant("answer")])

      graph = Presets.react(llm, [Search], rate_limiter: limiter)

      # limiter 슬롯을 미리 점유 → agent 노드의 LLM 호출이 블록되어야 한다.
      blocker =
        spawn(fn ->
          RateLimiter.acquire(limiter)
          Process.sleep(:infinity)
        end)

      task = Task.async(fn -> ElGraph.invoke(graph, %{messages: [LLM.user("hi")]}) end)
      refute Task.yield(task, 150)

      # 슬롯을 풀면 (blocker 종료 → 모니터 회수) 실행이 진행된다.
      Process.exit(blocker, :kill)
      assert {:ok, %{messages: messages}} = Task.await(task, 2_000)
      assert %{content: "answer"} = List.last(messages)
    end

    test "without a rate_limiter the preset runs unthrottled" do
      llm = scripted([LLM.assistant("answer")])
      graph = Presets.react(llm, [Search])

      assert {:ok, _state} = ElGraph.invoke(graph, %{messages: [LLM.user("hi")]})
    end
  end
end
