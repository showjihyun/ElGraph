defmodule ElGraph.Memory.Backend.ZepIntegrationTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory.Backend
  alias ElGraph.Memory.Backend.Zep
  alias ElGraph.Secrets

  @moduletag :integration
  @moduletag timeout: 60_000

  # 실 키 필요: env ZEP_API_KEY 또는 config/secrets.exs의 :zep_api_key.
  defp backend, do: {Zep, api_key: Secrets.fetch!(:zep_api_key)}

  test "remember then recall round-trips against the real Zep API" do
    # 테스트 격리: 매 실행 고유 user namespace.
    ns = ["el_graph_test", "u-#{System.unique_integer([:positive])}"]

    assert :ok = Backend.remember(backend(), ns, "The user's favorite language is Elixir.")

    # Zep은 그래프에 비동기로 사실을 추출·반영한다 — 잠깐 폴링한다.
    assert {:ok, hits} = poll_recall(backend(), ns, "what language does the user like?", 20)
    assert Enum.any?(hits, &(&1 =~ "Elixir"))
  end

  defp poll_recall(_backend, _ns, _query, 0), do: {:ok, []}

  defp poll_recall(backend, ns, query, tries) do
    case Backend.recall(backend, ns, query) do
      {:ok, [_ | _]} = hit ->
        hit

      _ ->
        receive do
        after
          1_000 -> :ok
        end

        poll_recall(backend, ns, query, tries - 1)
    end
  end
end
