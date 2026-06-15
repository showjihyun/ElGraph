defmodule ElGraph.Presets.ReActCodeExecTest do
  use ExUnit.Case, async: true

  alias ElGraph.{LLM, Presets}
  alias ElGraph.Actions.CodeExec
  alias ElGraph.Test.ScriptedLLM

  defmodule MockSandbox do
    @behaviour ElGraph.Sandbox

    @impl ElGraph.Sandbox
    def run(_code, _opts), do: {:ok, %{stdout: "42", exit_code: 0, truncated: false}}
  end

  test "CodeExec runs through the agent loop using the sandbox from ctx.assigns" do
    {:ok, pid} =
      ScriptedLLM.start_link([
        LLM.assistant(nil, [LLM.tool_call("c1", "code_exec", %{"code" => "IO.puts(42)"})]),
        LLM.assistant("the answer is 42")
      ])

    graph = Presets.react({ScriptedLLM, pid}, [CodeExec])

    assert {:ok, %{messages: messages}} =
             ElGraph.invoke(graph, %{messages: [LLM.user("compute 6*7")]},
               assigns: %{sandbox: {MockSandbox, []}}
             )

    assert [
             %{role: :user},
             %{role: :assistant, tool_calls: [%{name: "code_exec"}]},
             %{role: :tool, name: "code_exec", content: %{result: %{stdout: "42"}}},
             %{role: :assistant, content: "the answer is 42"}
           ] = messages
  end
end
