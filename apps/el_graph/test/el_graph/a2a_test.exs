defmodule ElGraph.A2ATest do
  use ExUnit.Case, async: true

  alias ElGraph.A2A

  doctest ElGraph.A2A

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

  describe "task_from_checkpoint/2 — durable run ↔ A2A Task (체크포인터 연동)" do
    alias ElGraph.Checkpointer.ETS

    defp ask_graph do
      ElGraph.new()
      |> ElGraph.state(:result)
      |> ElGraph.add_node(:ask, &ElGraph.TestNodes.ask/2)
      |> ElGraph.compile(entry: :ask)
    end

    setup do
      pid = start_supervised!(ETS)
      %{cp: {ETS, ETS.config(pid)}}
    end

    test "an interrupted run maps to INPUT_REQUIRED with the interrupt payload", %{cp: cp} do
      {:interrupted, _} = ElGraph.invoke(ask_graph(), %{}, checkpointer: cp, thread_id: "t1")

      assert %{id: "t1", status: %{state: "input-required", payload: %{question: "name?"}}} =
               A2A.task_from_checkpoint(cp, "t1")
    end

    test "a completed run maps to COMPLETED with the final state", %{cp: cp} do
      {:interrupted, _} = ElGraph.invoke(ask_graph(), %{}, checkpointer: cp, thread_id: "t2")
      {:ok, _} = ElGraph.resume(ask_graph(), checkpointer: cp, thread_id: "t2", resume: "Alice")

      assert %{id: "t2", status: %{state: "completed", result: %{result: "Alice"}}} =
               A2A.task_from_checkpoint(cp, "t2")
    end

    test "an in-progress checkpoint maps to WORKING", %{cp: {mod, config}} do
      :ok =
        mod.put(config, %ElGraph.Checkpoint{thread_id: "w", step: 1, state: %{}, next: [:more]})

      assert %{id: "w", status: %{state: "working"}} =
               A2A.task_from_checkpoint({mod, config}, "w")
    end

    test "an unknown thread maps to SUBMITTED", %{cp: cp} do
      assert %{id: "ghost", status: %{state: "submitted"}} = A2A.task_from_checkpoint(cp, "ghost")
    end

    test "works across any durable backend (contract-level)", %{cp: cp} do
      # DETS(무인프라 내구) 백엔드로도 동일하게 동작 — 어댑터 무관.
      path = Path.join(System.tmp_dir!(), "a2a_dets_#{System.unique_integer([:positive])}.dets")
      dets_pid = start_supervised!({ElGraph.Checkpointer.Dets, path: path}, id: :a2a_dets)
      on_exit(fn -> File.rm(path) end)
      dets_cp = {ElGraph.Checkpointer.Dets, ElGraph.Checkpointer.Dets.config(dets_pid)}

      {:interrupted, _} = ElGraph.invoke(ask_graph(), %{}, checkpointer: dets_cp, thread_id: "d1")
      assert %{status: %{state: "input-required"}} = A2A.task_from_checkpoint(dets_cp, "d1")

      _ = cp
    end
  end
end
