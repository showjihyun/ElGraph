defmodule ElGraph.SecretsTest do
  # System env는 전역 상태라 async: false.
  use ExUnit.Case, async: false

  alias ElGraph.Secrets

  test "fetch!/1 reads from the uppercased env var first (CI: GitHub Secrets)" do
    System.put_env("OPENAI_API_KEY", "env-key-123")
    on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

    assert Secrets.fetch!(:openai_api_key) == "env-key-123"
  end

  test "fetch!/1 raises a helpful error naming the env var when absent everywhere" do
    System.delete_env("NONEXISTENT_SECRET_XYZ")

    assert_raise RuntimeError, ~r/NONEXISTENT_SECRET_XYZ/, fn ->
      Secrets.fetch!(:nonexistent_secret_xyz)
    end
  end
end
