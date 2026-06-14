defmodule ElGraph.AGUITest do
  use ExUnit.Case, async: true

  alias ElGraph.AGUI

  describe "lifecycle event constructors" do
    test "run_started/2 builds a RUN_STARTED event" do
      assert %{"type" => "RUN_STARTED", "threadId" => "t1", "runId" => "r1"} =
               AGUI.run_started("t1", "r1")
    end

    test "run_finished/2 builds a RUN_FINISHED event" do
      assert %{"type" => "RUN_FINISHED", "threadId" => "t1", "runId" => "r1"} =
               AGUI.run_finished("t1", "r1")
    end

    test "run_error/1 builds a RUN_ERROR event with a message" do
      assert %{"type" => "RUN_ERROR", "message" => "boom"} = AGUI.run_error("boom")
    end

    test "state_snapshot/1 builds a STATE_SNAPSHOT event" do
      assert %{"type" => "STATE_SNAPSHOT", "snapshot" => %{answer: "42"}} =
               AGUI.state_snapshot(%{answer: "42"})
    end
  end

  describe "transform/3 — ElGraph stream → AG-UI event sequence" do
    defp el(event, node \\ :agent, step \\ 1),
      do: %{thread_id: "t1", step: step, node: node, event: event}

    test "wraps the stream in RUN_STARTED ... RUN_FINISHED" do
      elements = [el(:node_start), el(:node_end)]

      events = elements |> AGUI.transform("t1", "r1") |> Enum.to_list()

      assert [%{"type" => "RUN_STARTED"} | rest] = events
      assert %{"type" => "RUN_FINISHED"} = List.last(rest)
    end

    test "maps :node_start/:node_end to STEP_STARTED/STEP_FINISHED" do
      events =
        [el(:node_start, :search), el(:node_end, :search)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [
               %{"type" => "RUN_STARTED"},
               %{"type" => "STEP_STARTED", "stepName" => "search"},
               %{"type" => "STEP_FINISHED", "stepName" => "search"},
               %{"type" => "RUN_FINISHED"}
             ] = events
    end

    test "frames a token run with TEXT_MESSAGE_START/CONTENT/END per node" do
      events =
        [
          el(:node_start, :agent),
          el({:token, "Hel"}, :agent),
          el({:token, "lo"}, :agent),
          el(:node_end, :agent)
        ]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [
               %{"type" => "RUN_STARTED"},
               %{"type" => "STEP_STARTED", "stepName" => "agent"},
               %{"type" => "TEXT_MESSAGE_START", "messageId" => mid, "role" => "assistant"},
               %{"type" => "TEXT_MESSAGE_CONTENT", "messageId" => mid, "delta" => "Hel"},
               %{"type" => "TEXT_MESSAGE_CONTENT", "messageId" => mid, "delta" => "lo"},
               %{"type" => "TEXT_MESSAGE_END", "messageId" => mid},
               %{"type" => "STEP_FINISHED", "stepName" => "agent"},
               %{"type" => "RUN_FINISHED"}
             ] = events
    end

    test "maps {:tool_call, id, name, args} to TOOL_CALL_START/ARGS/END" do
      events =
        [el({:tool_call, "call_1", "web_search", %{q: "elixir"}}, :agent)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [
               %{"type" => "RUN_STARTED"},
               %{
                 "type" => "TOOL_CALL_START",
                 "toolCallId" => "call_1",
                 "toolCallName" => "web_search"
               },
               %{"type" => "TOOL_CALL_ARGS", "toolCallId" => "call_1", "delta" => args_json},
               %{"type" => "TOOL_CALL_END", "toolCallId" => "call_1"},
               %{"type" => "RUN_FINISHED"}
             ] = events

      assert args_json =~ "elixir"
    end

    test "{:done, result} emits STATE_SNAPSHOT before RUN_FINISHED" do
      events =
        [el({:done, {:ok, %{answer: "42"}}}, :agent)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [
               %{"type" => "RUN_STARTED"},
               %{"type" => "STATE_SNAPSHOT", "snapshot" => %{answer: "42"}},
               %{"type" => "RUN_FINISHED"}
             ] = events
    end

    test "an interrupted run surfaces STATE_SNAPSHOT + RUN_FINISHED with the payload" do
      events =
        [el({:done, {:interrupted, %{node: :approve, payload: %{question: "ok?"}}}}, :approve)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [
               %{"type" => "RUN_STARTED"},
               %{
                 "type" => "STATE_SNAPSHOT",
                 "snapshot" => %{node: :approve, payload: %{question: "ok?"}}
               },
               %{"type" => "RUN_FINISHED"}
             ] = events
    end

    test "{:done, {:error, reason}} emits RUN_ERROR instead of RUN_FINISHED" do
      events =
        [el({:done, {:error, :boom}}, :agent)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [%{"type" => "RUN_STARTED"}, %{"type" => "RUN_ERROR", "message" => msg}] = events
      assert msg =~ "boom"
    end

    test "{:down, reason} emits RUN_ERROR" do
      events =
        [%{thread_id: "t1", event: {:down, :killed}}]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [%{"type" => "RUN_STARTED"}, %{"type" => "RUN_ERROR", "message" => msg}] = events
      assert msg =~ "killed"
    end

    test "closes an open message if the node ends via a terminal event" do
      events =
        [
          el({:token, "hi"}, :agent),
          el({:done, {:ok, %{}}}, :agent)
        ]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      types = Enum.map(events, & &1["type"])
      # the open text message must be closed before the run finishes
      assert "TEXT_MESSAGE_END" in types
      assert List.last(types) == "RUN_FINISHED"
    end

    test "ignores unknown user events" do
      events =
        [el({:custom, :whatever}, :agent)]
        |> AGUI.transform("t1", "r1")
        |> Enum.to_list()

      assert [%{"type" => "RUN_STARTED"}, %{"type" => "RUN_FINISHED"}] = events
    end
  end
end
