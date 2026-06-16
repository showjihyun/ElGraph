defmodule ElGraph.Memory.Backend.Mem0 do
  @moduledoc """
  [Mem0](https://mem0.ai) 관리형 메모리 REST API 위임 백엔드.

  config(keyword):

    * `:api_key` (필수) — Mem0 API 키. `Authorization: Token <key>`로 전송.
    * `:base_url` — 기본 `"https://api.mem0.ai"`.
    * `:req_options` — Req에 덧붙일 옵션(테스트의 `plug: {Req.Test, _}` 주입용).

  namespace는 `:`로 이어 Mem0 `user_id`로 매핑한다(예: `["users","u1"] -> "users:u1"`).
  어댑터는 자체 재시도를 하지 않는다 — 호출 측 정책이 담당한다.
  """

  @behaviour ElGraph.Memory.Backend

  @base_url "https://api.mem0.ai"

  @impl true
  def remember(config, ns, text, _opts) when is_binary(text) do
    body = %{messages: [%{role: "user", content: text}], user_id: user_id(ns)}

    case post(config, "/v1/memories/", body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  @impl true
  def recall(config, ns, query, opts) do
    body =
      %{query: query, user_id: user_id(ns)}
      |> put_present(:top_k, Keyword.get(opts, :limit))

    case post(config, "/v1/memories/search/", body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, extract_memories(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:transport_error, exception}}
    end
  end

  defp post(config, path, body) do
    base = Keyword.get(config, :base_url, @base_url)
    req_options = Keyword.get(config, :req_options, [])
    headers = [{"authorization", "Token #{Keyword.fetch!(config, :api_key)}"}]

    Req.post(base <> path, [json: body, headers: headers, retry: false] ++ req_options)
  end

  # Mem0 search는 `%{"results" => [...]}` 또는 bare 리스트로 응답한다 — 둘 다 수용.
  defp extract_memories(%{"results" => results}), do: extract_memories(results)
  defp extract_memories(results) when is_list(results), do: Enum.map(results, & &1["memory"])
  defp extract_memories(_), do: []

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp user_id(ns), do: Enum.join(ns, ":")
end
