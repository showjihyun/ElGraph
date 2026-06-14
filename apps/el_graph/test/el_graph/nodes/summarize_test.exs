defmodule ElGraph.Nodes.SummarizeTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Reducers}
  alias ElGraph.Nodes.Summarize
  alias ElGraph.Store.ETS, as: Store
  alias ElGraph.Test.ScriptedLLM

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {pid, {ScriptedLLM, pid}}
  end

  defp msgs(n), do: for(i <- 1..n, do: LLM.user("m#{i}"))

  describe "append reducer replace marker" do
    test "{:replace, list} replaces the channel instead of appending" do
      assert ["x", "y"] = Reducers.append(["a", "b", "c"], {:replace, ["x", "y"]})
    end

    test "normal appends still work" do
      assert ["a", "b"] = Reducers.append(["a"], "b")
    end
  end

  describe "Summarize node (SPEC §4)" do
    test "passes through unchanged when under the trigger" do
      {_pid, llm} = scripted([])
      state = %{messages: msgs(5)}

      assert %{} ==
               Summarize.run(state, %{}, llm: llm, trigger: {:messages, 20}, keep: {:messages, 6})
    end

    test "replaces old messages with a summary, keeping the most recent N" do
      {_pid, llm} = scripted([LLM.assistant("요약: m1~m4")])
      state = %{messages: msgs(10)}

      assert %{messages: {:replace, replaced}} =
               Summarize.run(state, %{}, llm: llm, trigger: {:messages, 8}, keep: {:messages, 6})

      # [요약 메시지 | 최근 6개]
      assert [%{content: summary} | recent] = replaced
      assert summary =~ "요약"
      assert length(recent) == 6
      assert List.last(recent).content == "m10"
    end

    test "the summarizer LLM receives the evicted messages" do
      {pid, llm} = scripted([LLM.assistant("요약본")])
      state = %{messages: msgs(10)}

      Summarize.run(state, %{}, llm: llm, trigger: {:messages, 8}, keep: {:messages, 6})

      assert [call] = ScriptedLLM.calls(pid)
      # 축출된 m1~m4의 내용이 요약 프롬프트에 포함된다.
      prompt = call.messages |> Enum.map_join(" ", & &1.content)
      assert prompt =~ "m1"
      assert prompt =~ "m4"
      refute prompt =~ "m10"
    end

    test "evicted messages are written to the store when configured" do
      {_pid, llm} = scripted([LLM.assistant("요약")])
      store_pid = start_supervised!(Store)
      store = {Store, Store.config(store_pid), ["conv", "c1"]}
      state = %{messages: msgs(10)}

      Summarize.run(state, %{},
        llm: llm,
        trigger: {:messages, 8},
        keep: {:messages, 6},
        store: store
      )

      # 축출분(m1~m4)이 store에 보관된다.
      entries = Store.list(Store.config(store_pid), ["conv", "c1"])
      assert length(entries) == 1
      assert [{_key, evicted}] = entries
      assert length(evicted) == 4
    end
  end
end
