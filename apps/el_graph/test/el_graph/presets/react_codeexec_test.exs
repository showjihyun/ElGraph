# async: false — this test sets a global Application env (:code_exec_sandbox) because in a
# graph the tool context is an ElGraph.Ctx (not a map with :sandbox), so CodeExec falls back
# to Application.get_env. Mutating Application env is process-global, so it cannot run
# concurrently with other tests that might read the same key.
defmodule ElGraph.Presets.ReActCodeExecTest do
  use ExUnit.Case, async: false

  alias ElGraph.{LLM, Presets}
  alias ElGraph.Actions.CodeExec
  alias ElGraph.Test.ScriptedLLM

  defmodule MockSandbox do
    @behaviour ElGraph.Sandbox

    @impl ElGraph.Sandbox
    def run(_code, _opts), do: {:ok, %{stdout: "42", exit_code: 0, truncated: false}}
  end

  setup do
    Application.put_env(:el_graph, :code_exec_sandbox, {MockSandbox, []})
    on_exit(fn -> Application.delete_env(:el_graph, :code_exec_sandbox) end)
    :ok
  end

  test "CodeExec runs through the agent loop using the configured sandbox" do
    {:ok, pid} =
      ScriptedLLM.start_link([
        LLM.assistant(nil, [LLM.tool_call("c1", "code_exec", %{"code" => "IO.puts(42)"})]),
        LLM.assistant("the answer is 42")
      ])

    graph = Presets.react({ScriptedLLM, pid}, [CodeExec])

    assert {:ok, %{messages: messages}} =
             ElGraph.invoke(graph, %{messages: [LLM.user("compute 6*7")]})

    assert [
             %{role: :user},
             %{role: :assistant, tool_calls: [%{name: "code_exec"}]},
             %{role: :tool, name: "code_exec", content: %{result: %{stdout: "42"}}},
             %{role: :assistant, content: "the answer is 42"}
           ] = messages
  end
end
