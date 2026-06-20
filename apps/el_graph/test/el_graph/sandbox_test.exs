defmodule ElGraph.SandboxTest do
  use ExUnit.Case, async: true

  alias ElGraph.Sandbox

  describe "interpreter/1 — shared language table" do
    test "resolves a known language to {cmd, flag}" do
      assert {:ok, {"elixir", "-e"}} = Sandbox.interpreter("elixir")
      assert {:ok, {"python", "-c"}} = Sandbox.interpreter("python")
      assert {:ok, {"bash", "-c"}} = Sandbox.interpreter("bash")
    end

    test "rejects an unsupported language" do
      assert {:error, {:unsupported_language, "brainfuck"}} = Sandbox.interpreter("brainfuck")
    end
  end

  describe "exec/3 — shared run + result mapping" do
    test "maps exit 0 to {:ok, result}" do
      parent = self()
      runner = fn cmd, args, _opts -> send(parent, {:ran, cmd, args}) && {"out\n", 0} end

      assert {:ok, %{stdout: "out\n", exit_code: 0, truncated: false}} =
               Sandbox.exec("elixir", ["-e", "x"], runner: runner)

      assert_received {:ran, "elixir", ["-e", "x"]}
    end

    test "maps a non-zero exit to {:error, {:exit, code, output}}" do
      runner = fn _, _, _ -> {"boom\n", 2} end
      assert {:error, {:exit, 2, "boom\n"}} = Sandbox.exec("cmd", [], runner: runner)
    end

    test "isolates a runner that exceeds the timeout as {:error, :timeout}" do
      runner = fn _, _, _ -> receive do: (:never -> :ok) end
      assert {:error, :timeout} = Sandbox.exec("cmd", [], runner: runner, timeout: 50)
    end

    test "truncates stdout to :max_output and flags truncated: true" do
      runner = fn _, _, _ -> {String.duplicate("x", 100), 0} end

      assert {:ok, %{stdout: out, truncated: true}} =
               Sandbox.exec("cmd", [], runner: runner, max_output: 10)

      assert out == String.duplicate("x", 10)
    end

    test "leaves output intact (truncated: false) without :max_output" do
      runner = fn _, _, _ -> {"short", 0} end
      assert {:ok, %{stdout: "short", truncated: false}} = Sandbox.exec("cmd", [], runner: runner)
    end
  end
end
