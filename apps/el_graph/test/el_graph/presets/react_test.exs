defmodule ElGraph.Presets.ReActTest do
  use ExUnit.Case, async: true

  alias ElGraph.{FakeMCPClient, LLM, MCP, Presets}
  alias ElGraph.TestActions.Search
  alias ElGraph.Test.ScriptedLLM

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {pid, {ScriptedLLM, pid}}
  end

  describe "react/3: 기본 루프" do
    test "direct answer without tool calls ends after one turn" do
      {_pid, llm} = scripted([LLM.assistant("안녕!")])
      graph = Presets.react(llm, [Search])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("hi")]})

      assert [%{role: :user}, %{role: :assistant, content: "안녕!"}] = messages
    end

    test "tool-call loop: agent → tools → agent → end" do
      {_pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "elixir"})]),
          LLM.assistant("결과 요약")
        ])

      graph = Presets.react(llm, [Search])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("검색해줘")]})

      assert [
               %{role: :user},
               %{role: :assistant, tool_calls: [%{name: "web_search"}]},
               %{
                 role: :tool,
                 tool_call_id: "c1",
                 name: "web_search",
                 content: %{results: ["r:elixir:5"]}
               },
               %{role: :assistant, content: "결과 요약"}
             ] = messages
    end

    test "the next LLM call receives the tool result and the tool specs" do
      {pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "q"})]),
          LLM.assistant("done")
        ])

      graph = Presets.react(llm, [Search])
      {:ok, _state} = ElGraph.invoke(graph, %{messages: [LLM.user("go")]})

      assert [first_call, second_call] = ScriptedLLM.calls(pid)
      assert [%{role: :user}] = first_call.messages
      assert [%{name: "web_search"}] = first_call.opts[:tools]
      assert Enum.any?(second_call.messages, &match?(%{role: :tool}, &1))
    end
  end

  describe "react/3: 복구 가능한 툴 실패" do
    test "unknown tool names become recoverable tool error messages" do
      {_pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "bogus_tool", %{})]),
          LLM.assistant("복구했다")
        ])

      graph = Presets.react(llm, [Search])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})

      assert [
               _user,
               _assistant,
               %{role: :tool, name: "bogus_tool", content: "error: " <> _},
               %{content: "복구했다"}
             ] =
               messages
    end

    test "tool validation errors become recoverable tool error messages" do
      {_pid, llm} =
        scripted([
          # 필수 파라미터 query 누락
          LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{})]),
          LLM.assistant("복구했다")
        ])

      graph = Presets.react(llm, [Search])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})

      assert [_user, _assistant, %{role: :tool, content: "error: " <> _}, %{content: "복구했다"}] =
               messages
    end
  end

  describe "react/3: MCP 혼용과 LLM 실패" do
    test "MCP tools are usable alongside actions" do
      weather_def = %{
        "name" => "get_weather",
        "description" => "날씨",
        "inputSchema" => %{"type" => "object"}
      }

      {:ok, mcp_tools} =
        MCP.tools({FakeMCPClient, %{tools: [weather_def], owner: self()}})

      {_pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "get_weather", %{"city" => "Seoul"})]),
          LLM.assistant("맑음")
        ])

      graph = Presets.react(llm, [Search | mcp_tools])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("날씨?")]})

      assert_receive {:mcp_call, "get_weather", %{"city" => "Seoul"}}

      assert [_u, _a, %{role: :tool, content: %{"echoed" => %{"city" => "Seoul"}}}, _final] =
               messages
    end

    test "LLM errors crash the agent node (retry-composable)" do
      {_pid, llm} = scripted([{:error, :rate_limited}])
      graph = Presets.react(llm, [Search])

      assert {:error, {:node_crashed, :agent, %ElGraph.LLMError{reason: :rate_limited}}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})
    end

    test "an exhausted script is an explicit error" do
      {_pid, llm} = scripted([])
      graph = Presets.react(llm, [Search])

      assert {:error, {:node_crashed, :agent, %ElGraph.LLMError{reason: :script_exhausted}}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("go")]})
    end
  end
end
