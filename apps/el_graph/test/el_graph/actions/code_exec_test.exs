defmodule ElGraph.Actions.CodeExecTest do
  use ExUnit.Case, async: true

  alias ElGraph.Actions.CodeExec

  defmodule MockSandbox do
    @behaviour ElGraph.Sandbox
    @impl true
    def run(code, opts) do
      send(self(), {:sandbox_called, code, opts})
      {:ok, %{stdout: "ran: " <> code, exit_code: 0}}
    end
  end

  defmodule FailSandbox do
    @behaviour ElGraph.Sandbox
    @impl true
    def run(_code, _opts), do: {:error, :sandbox_unavailable}
  end

  describe "as an LLM tool" do
    test "to_tool_spec exposes code (required) and language" do
      assert %{
               name: "code_exec",
               input_schema: %{
                 "properties" => %{"code" => _, "language" => _},
                 "required" => ["code"]
               }
             } = CodeExec.to_tool_spec()
    end
  end

  describe "run/2 — delegates to the configured sandbox backend" do
    test "delegates to a sandbox provided via context and wraps the result" do
      ctx = %{sandbox: {MockSandbox, []}}

      assert {:ok, %{result: %{stdout: "ran: 1+1"}}} =
               CodeExec.execute(%{"code" => "1+1", "language" => "elixir"}, ctx)

      assert_received {:sandbox_called, "1+1", opts}
      assert opts[:language] == "elixir"
    end

    test "surfaces a sandbox error" do
      ctx = %{sandbox: {FailSandbox, []}}
      assert {:error, :sandbox_unavailable} = CodeExec.execute(%{"code" => "x"}, ctx)
    end

    test "errors clearly when no sandbox is configured (never evals in-process)" do
      assert {:error, :no_sandbox_configured} = CodeExec.execute(%{"code" => "x"}, %{})
    end
  end
end
