defmodule ElGraph.OrchestrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Orchestration}
  alias ElGraph.Test.ScriptedLLM

  # 워커 노드 함수 (원격 캡처 — durable 계약).
  defmodule Workers do
    def research(_state, _ctx), do: %{messages: [LLM.assistant("research: found 3 facts")]}
    def write(_state, _ctx), do: %{messages: [LLM.assistant("write: drafted summary")]}
  end

  defp workers do
    [
      %{name: :researcher, description: "gathers facts", run: &Workers.research/2},
      %{name: :writer, description: "writes the final answer", run: &Workers.write/2}
    ]
  end

  defmodule Speakers do
    def alice(_state, _ctx), do: %{messages: [LLM.assistant("alice")]}
    def bob(_state, _ctx), do: %{messages: [LLM.assistant("bob")]}
  end

  defp speakers do
    [
      %{name: :alice, description: "a", run: &Speakers.alice/2},
      %{name: :bob, description: "b", run: &Speakers.bob/2}
    ]
  end

  describe "group_chat/2 — speaker selection" do
    test "default round-robin cycles speakers for the given rounds" do
      graph = Orchestration.group_chat(speakers(), rounds: 3)

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("start")]})

      spoken = for %{role: :assistant, content: c} <- messages, do: c
      assert ["alice", "bob", "alice"] == spoken
    end

    test "a custom selector decides the next speaker and termination" do
      # only bob speaks, once
      select = fn %{turn: turn} -> if turn == 0, do: :bob, else: :end end
      graph = Orchestration.group_chat(speakers(), select: select)

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("start")]})

      spoken = for %{role: :assistant, content: c} <- messages, do: c
      assert ["bob"] == spoken
    end

    test "terminates with no speakers when rounds is 0" do
      graph = Orchestration.group_chat(speakers(), rounds: 0)

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("start")]})

      assert [] == for(%{role: :assistant} <- messages, do: :x)
    end
  end

  describe "supervisor/3 — orchestrator-worker" do
    test "routes to each chosen worker then terminates on DONE" do
      # orchestrator LLM picks: researcher → writer → DONE
      {:ok, llm} =
        ScriptedLLM.start_link([
          LLM.assistant("researcher"),
          LLM.assistant("writer"),
          LLM.assistant("DONE")
        ])

      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers(), [])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("Write a report")]})

      contents = for %{content: c} when is_binary(c) <- messages, do: c

      assert "research: found 3 facts" in contents
      assert "write: drafted summary" in contents
      # worker outputs appear in delegation order
      assert Enum.find_index(contents, &(&1 == "research: found 3 facts")) <
               Enum.find_index(contents, &(&1 == "write: drafted summary"))
    end

    test "terminates immediately when the orchestrator says DONE first" do
      {:ok, llm} = ScriptedLLM.start_link([LLM.assistant("DONE")])
      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers(), [])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("noop")]})

      contents = for %{content: c} when is_binary(c) <- messages, do: c
      refute "research: found 3 facts" in contents
      refute "write: drafted summary" in contents
    end

    test "an unrecognized orchestrator choice terminates safely (no crash)" do
      {:ok, llm} = ScriptedLLM.start_link([LLM.assistant("???garbage???")])
      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers(), [])

      assert {:ok, %{messages: _}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("x")]})
    end

    test "accumulates usage across orchestrator turns" do
      {:ok, llm} =
        ScriptedLLM.start_link([LLM.assistant("researcher"), LLM.assistant("DONE")])

      graph = Orchestration.supervisor({ScriptedLLM, llm}, workers(), [])

      assert {:ok, %{usage: %{input_tokens: _, output_tokens: _}}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})
    end
  end
end
