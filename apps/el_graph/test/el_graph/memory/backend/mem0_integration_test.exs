defmodule ElGraph.Memory.Backend.Mem0IntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory.Backend
  alias ElGraph.Memory.Backend.Mem0
  alias ElGraph.Secrets

  @moduletag :integration
  @moduletag timeout: 60_000

  # 실 키 필요: env MEM0_API_KEY 또는 config/secrets.exs의 :mem0_api_key.
  defp backend, do: {Mem0, api_key: Secrets.fetch!(:mem0_api_key)}

  test "remember then recall round-trips against the real Mem0 API" do
    # 테스트 격리: 매 실행 고유 namespace (이전 잔여 메모리 영향 배제).
    ns = ["el_graph_test", "u-#{System.unique_integer([:positive])}"]

    assert :ok = Backend.remember(backend(), ns, "The user's favorite language is Elixir.")

    assert {:ok, hits} = Backend.recall(backend(), ns, "what language does the user like?")
    assert Enum.any?(hits, &(&1 =~ "Elixir"))
  end
end
