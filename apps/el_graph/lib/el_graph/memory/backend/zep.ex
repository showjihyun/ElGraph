defmodule ElGraph.Memory.Backend.Zep do
  @moduledoc """
  [Zep](https://getzep.com) temporal knowledge-graph 메모리 위임 백엔드.

  config(keyword):

    * `:api_key` (필수) — Zep API 키. `Authorization: Api-Key <key>`로 전송.
    * `:base_url` — 기본 `"https://api.getzep.com/api/v2"`.
    * `:req_options` — Req에 덧붙일 옵션(테스트의 `plug: {Req.Test, _}` 주입용).

  Zep graph API에 매핑한다:

    * `remember` → `POST /graph` (`type: "text"`).
    * `recall`   → `POST /graph/search` (`scope: "edges"`) — 시점 인지 지식그래프에서
      추출된 **사실(edge `fact`)** 목록을 회수한다(ElGraph의 시점진실 facts와 결이 맞다).

  namespace는 `:`로 이어 Zep `user_id`로 매핑한다. 자체 재시도는 하지 않는다.
  """

  @behaviour ElGraph.Memory.Backend

  @base_url "https://api.getzep.com/api/v2"

  @impl true
  def remember(config, ns, text, _opts) when is_binary(text) do
    body = %{data: text, type: "text", user_id: user_id(ns)}

    case post(config, "/graph", body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  @impl true
  def recall(config, ns, query, opts) do
    body =
      %{query: query, user_id: user_id(ns), scope: "edges"}
      |> put_present(:limit, Keyword.get(opts, :limit))

    case post(config, "/graph/search", body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, extract_facts(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:transport_error, exception}}
    end
  end

  defp post(config, path, body) do
    base = Keyword.get(config, :base_url, @base_url)
    req_options = Keyword.get(config, :req_options, [])
    headers = [{"authorization", "Api-Key #{Keyword.fetch!(config, :api_key)}"}]

    Req.post(base <> path, [json: body, headers: headers, retry: false] ++ req_options)
  end

  # graph/search 응답의 edges[].fact를 회수한다(edge 없으면 []).
  defp extract_facts(%{"edges" => edges}) when is_list(edges), do: Enum.map(edges, & &1["fact"])
  defp extract_facts(_), do: []

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp user_id(ns), do: Enum.join(ns, ":")
end
