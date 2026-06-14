defmodule ElGraph.Test.ScriptedLLMTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.Test.ScriptedLLM

  describe "stream_chat/3 — scripted streaming" do
    test "emits the content as a token delta and returns the assembled response" do
      {:ok, pid} = ScriptedLLM.start_link([LLM.assistant("Hello world")])
      parent = self()

      assert {:ok, %{message: %{role: :assistant, content: "Hello world"}}} =
               ScriptedLLM.stream_chat(pid, [LLM.user("hi")],
                 on_delta: fn ev -> send(parent, {:delta, ev}) end
               )

      assert_received {:delta, {:token, "Hello world"}}
    end

    test "splits a {:deltas, parts, message} script item into multiple token deltas" do
      msg = LLM.assistant("Hel" <> "lo")
      {:ok, pid} = ScriptedLLM.start_link([{:deltas, ["Hel", "lo"], msg}])
      parent = self()

      assert {:ok, %{message: %{content: "Hello"}}} =
               ScriptedLLM.stream_chat(pid, [LLM.user("hi")],
                 on_delta: fn ev -> send(parent, {:delta, ev}) end
               )

      assert_received {:delta, {:token, "Hel"}}
      assert_received {:delta, {:token, "lo"}}
    end

    test "records the call like chat/3 does" do
      {:ok, pid} = ScriptedLLM.start_link([LLM.assistant("ok")])
      ScriptedLLM.stream_chat(pid, [LLM.user("q")], on_delta: fn _ -> :ok end)

      assert [%{messages: [%{role: :user, content: "q"}]}] = ScriptedLLM.calls(pid)
    end
  end

  describe "LLM.stream_supported?/1" do
    test "true when the adapter exports stream_chat/3" do
      {:ok, pid} = ScriptedLLM.start_link([])
      assert LLM.stream_supported?({ScriptedLLM, pid})
    end

    test "false for an adapter without stream_chat/3" do
      refute LLM.stream_supported?({ElGraph.Test.ScriptedLLMTest.NoStream, nil})
    end
  end

  defmodule NoStream do
    @moduledoc false
    @behaviour ElGraph.LLM
    @impl true
    def chat(_config, _messages, _opts),
      do: {:ok, %{message: ElGraph.LLM.assistant("x"), usage: nil}}
  end
end
