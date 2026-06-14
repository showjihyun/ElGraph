defmodule ElGraph.Sandbox.CommandTest do
  use ExUnit.Case, async: true

  alias ElGraph.Sandbox.Command

  describe "run/2 — delegates to an external interpreter" do
    test "builds interpreter argv and maps a successful run" do
      parent = self()

      runner = fn cmd, args, _opts ->
        send(parent, {:ran, cmd, args})
        {"4\n", 0}
      end

      assert {:ok, %{stdout: "4\n", exit_code: 0}} =
               Command.run("IO.puts(2+2)", language: "elixir", runner: runner)

      assert_received {:ran, "elixir", ["-e", "IO.puts(2+2)"]}
    end

    test "maps a non-zero exit to an error with output" do
      runner = fn _cmd, _args, _opts -> {"boom\n", 1} end

      assert {:error, {:exit, 1, "boom\n"}} =
               Command.run("raise 1", language: "elixir", runner: runner)
    end

    test "rejects an unsupported language" do
      assert {:error, {:unsupported_language, "brainfuck"}} =
               Command.run("+++", language: "brainfuck", runner: fn _, _, _ -> {"", 0} end)
    end

    test "supports python" do
      parent = self()
      runner = fn cmd, args, _opts -> send(parent, {:ran, cmd, args}) && {"hi\n", 0} end
      assert {:ok, _} = Command.run("print('hi')", language: "python", runner: runner)
      assert_received {:ran, "python", ["-c", "print('hi')"]}
    end
  end
end
