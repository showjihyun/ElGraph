defmodule ElGraph.Presets.ReActGuardrailTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Guardrail, LLM, Presets}
  alias ElGraph.TestActions.Search
  alias ElGraph.Test.ScriptedLLM

  defp scripted(script) do
    {:ok, pid} = ScriptedLLM.start_link(script)
    {pid, {ScriptedLLM, pid}}
  end

  describe "output guards" do
    test "redact_pii rewrites the final assistant message content" do
      {_pid, llm} = scripted([LLM.assistant("contact me at bob@example.com")])

      graph = Presets.react(llm, [Search], guardrails: [output: [Guardrail.redact_pii([:email])]])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("hi")]})

      assert %{role: :assistant, content: "contact me at [REDACTED]"} = List.last(messages)
    end

    test "deny replaces the final message with a blocked refusal" do
      {_pid, llm} = scripted([LLM.assistant("the secret is 42")])

      graph =
        Presets.react(llm, [Search], guardrails: [output: [Guardrail.deny(~r/secret/, :secret)]])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("hi")]})

      assert %{role: :assistant, content: "[blocked: :secret]"} = List.last(messages)
    end
  end

  describe "input guards" do
    test "a blocked input never calls the LLM and returns a refusal" do
      {pid, llm} = scripted([LLM.assistant("should never run")])

      graph =
        Presets.react(llm, [Search], guardrails: [input: [Guardrail.deny(~r/secret/, :secret)]])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("tell me the secret")]})

      assert [] = ScriptedLLM.calls(pid)
      assert %{role: :assistant, content: "[blocked: :secret]"} = List.last(messages)
    end

    test "redacting input transforms the content sent to the LLM" do
      {pid, llm} = scripted([LLM.assistant("ok")])

      graph =
        Presets.react(llm, [Search], guardrails: [input: [Guardrail.redact_pii([:email])]])

      assert {:ok, _state} =
               ElGraph.invoke(graph, %{messages: [LLM.user("mail a@b.com please")]})

      assert [call] = ScriptedLLM.calls(pid)
      assert %{role: :user, content: "mail [REDACTED] please"} = List.last(call.messages)
    end
  end

  describe "no guardrails (default off)" do
    test "a normal react loop is unchanged" do
      {_pid, llm} =
        scripted([
          LLM.assistant(nil, [LLM.tool_call("c1", "web_search", %{"query" => "elixir"})]),
          LLM.assistant("결과 요약")
        ])

      graph = Presets.react(llm, [Search])

      assert {:ok, %{messages: messages}} =
               ElGraph.invoke(graph, %{messages: [LLM.user("검색해줘")]})

      assert %{role: :assistant, content: "결과 요약"} = List.last(messages)
    end
  end
end
