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

  describe "run/2 — timeout (:timeout opt)" do
    test "returns {:error, :timeout} when the runner exceeds the timeout" do
      # 멈춘(hang) 프로세스 시뮬레이션 — 타임아웃이 Task를 죽일 때까지 블록한다.
      # (Process.sleep는 TDD-SPEC 금지 — receive로 동등하게 블록)
      runner = fn _, _, _ -> receive do: (:never -> :ok) end

      assert {:error, :timeout} =
               Command.run("loop", language: "elixir", runner: runner, timeout: 50)
    end

    test "completes normally when the runner finishes within the timeout" do
      runner = fn _, _, _ -> {"ok\n", 0} end

      assert {:ok, %{stdout: "ok\n", exit_code: 0, truncated: false}} =
               Command.run("fast", language: "elixir", runner: runner, timeout: 1000)
    end
  end

  describe "run/2 — output-size limit (:max_output opt)" do
    test "truncates stdout to :max_output bytes and flags truncated: true" do
      runner = fn _, _, _ -> {String.duplicate("x", 100), 0} end

      assert {:ok, %{stdout: out, exit_code: 0, truncated: true}} =
               Command.run("big", language: "elixir", runner: runner, max_output: 10)

      assert out == String.duplicate("x", 10)
    end

    test "leaves short output intact and flags truncated: false" do
      runner = fn _, _, _ -> {"short\n", 0} end

      assert {:ok, %{stdout: "short\n", exit_code: 0, truncated: false}} =
               Command.run("small", language: "elixir", runner: runner, max_output: 1000)
    end

    test "flags truncated: false when no :max_output is given" do
      runner = fn _, _, _ -> {"hello\n", 0} end

      assert {:ok, %{stdout: "hello\n", exit_code: 0, truncated: false}} =
               Command.run("hi", language: "elixir", runner: runner)
    end
  end
end
