defmodule ElGraph.Sandbox.DockerTest do
  use ExUnit.Case, async: true

  alias ElGraph.Sandbox.Docker

  describe "run/2 — builds a hardened docker run argv" do
    test "uses safe defaults: --rm, --network=none, --read-only, memory, cpus" do
      parent = self()

      runner = fn cmd, args, _opts ->
        send(parent, {:ran, cmd, args})
        {"ok\n", 0}
      end

      assert {:ok, %{stdout: "ok\n", exit_code: 0, truncated: false}} =
               Docker.run("IO.puts(:ok)", language: "elixir", runner: runner)

      assert_received {:ran, "docker", args}
      assert "run" in args
      assert "--rm" in args
      assert "--network=none" in args
      assert "--read-only" in args
      assert "--memory=256m" in args
      assert "--cpus=1" in args
      assert "elixir:1.18-slim" in args
      # interpreter + flag + code appear in order at the tail
      assert List.last(args) == "IO.puts(:ok)"
      assert ["elixir", "-e", "IO.puts(:ok)"] == Enum.take(args, -3)
    end

    test "honours :memory, :cpus, :network and :image overrides" do
      parent = self()
      runner = fn cmd, args, _ -> send(parent, {:ran, cmd, args}) && {"", 0} end

      assert {:ok, _} =
               Docker.run("print(1)",
                 language: "python",
                 image: "my/python",
                 memory: "512m",
                 cpus: "2",
                 network: "bridge",
                 runner: runner
               )

      assert_received {:ran, "docker", args}
      assert "--memory=512m" in args
      assert "--cpus=2" in args
      assert "--network=bridge" in args
      assert "my/python" in args
      assert ["python", "-c", "print(1)"] == Enum.take(args, -3)
    end

    test "default images per language" do
      parent = self()
      runner = fn _, args, _ -> send(parent, {:args, args}) && {"", 0} end

      assert {:ok, _} = Docker.run("print(1)", language: "python", runner: runner)
      assert_received {:args, py_args}
      assert "python:3.12-slim" in py_args

      assert {:ok, _} = Docker.run("console.log(1)", language: "node", runner: runner)
      assert_received {:args, node_args}
      assert "node:22-slim" in node_args
    end
  end

  describe "run/2 — result mapping" do
    test "maps a non-zero exit to {:error, {:exit, code, out}}" do
      runner = fn _, _, _ -> {"boom\n", 2} end

      assert {:error, {:exit, 2, "boom\n"}} =
               Docker.run("raise 1", language: "elixir", runner: runner)
    end

    test "rejects an unsupported language" do
      assert {:error, {:unsupported_language, "brainfuck"}} =
               Docker.run("+++", language: "brainfuck", runner: fn _, _, _ -> {"", 0} end)
    end

    test "returns {:error, :timeout} when the runner exceeds :timeout" do
      # 멈춘(hang) 프로세스 시뮬레이션 — 타임아웃이 Task를 죽일 때까지 블록한다.
      # (Process.sleep는 TDD-SPEC 금지 — receive로 동등하게 블록)
      runner = fn _, _, _ -> receive do: (:never -> :ok) end

      assert {:error, :timeout} =
               Docker.run("loop", language: "elixir", runner: runner, timeout: 50)
    end

    test "truncates stdout to :max_output and flags truncated: true" do
      runner = fn _, _, _ -> {String.duplicate("y", 100), 0} end

      assert {:ok, %{stdout: out, exit_code: 0, truncated: true}} =
               Docker.run("big", language: "elixir", runner: runner, max_output: 5)

      assert out == String.duplicate("y", 5)
    end
  end
end
