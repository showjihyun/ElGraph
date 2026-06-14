defmodule ElGraph.Sandbox.CommandIntegrationTest do
  # Real interpreter — excluded by default (mix test --only integration).
  use ExUnit.Case, async: false
  @moduletag :integration

  alias ElGraph.Sandbox.Command

  describe "run/2 — against a real elixir interpreter" do
    test "executes code and captures stdout" do
      assert {:ok, %{stdout: out, exit_code: 0, truncated: false}} =
               Command.run("IO.puts(40 + 2)", language: "elixir")

      assert out =~ "42"
    end
  end
end
