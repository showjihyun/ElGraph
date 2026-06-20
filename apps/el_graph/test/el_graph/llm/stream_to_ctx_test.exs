defmodule ElGraph.LLM.StreamToCtxTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.Test.ScriptedLLM

  defp ctx,
    do: %ElGraph.Ctx{
      thread_id: "t",
      step: 0,
      node: :n,
      private: %ElGraph.Ctx.Internal{event_sink: self()}
    }

  describe "stream_to_ctx/4" do
    test "emits each streamed delta to the ctx event sink and returns the response" do
      {:ok, pid} = ScriptedLLM.start_link([{:deltas, ["Hel", "lo"], LLM.assistant("Hello")}])

      assert {:ok, %{message: %{role: :assistant, content: "Hello"}}} =
               LLM.stream_to_ctx({ScriptedLLM, pid}, [LLM.user("hi")], [], ctx())

      assert_receive {:el_graph_event, %{thread_id: "t", node: :n, event: {:token, "Hel"}}}
      assert_receive {:el_graph_event, %{event: {:token, "lo"}}}
    end

    test "propagates an error result from the adapter" do
      {:ok, pid} = ScriptedLLM.start_link([{:error, :boom}])

      assert {:error, :boom} =
               LLM.stream_to_ctx({ScriptedLLM, pid}, [LLM.user("hi")], [], ctx())
    end
  end
end
