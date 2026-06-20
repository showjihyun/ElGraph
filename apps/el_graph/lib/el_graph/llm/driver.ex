defmodule ElGraph.LLM.Driver do
  @moduledoc """
  모든 `ElGraph.LLM.Provider`를 구동하는 공유 머신 (전송·SSE·delta·fold·usage·telemetry).

  세 어댑터에 복제돼 있던 plumbing을 한곳에 모은다 — Provider는 매핑(`request_spec`·
  `parse_response`·`decode_deltas`·`decode_usage`)만 공급하고, 여기서:

    * `chat/5` — `instrument → Req.post → status 매핑 → Provider.parse_response`
    * `stream_chat/5` — `instrument → Req.post(into: collector) → status 매핑`,
      collector는 SSE를 한 번 프레이밍해 청크마다 `Provider.decode_deltas/2`로 delta를 얻고
      **실시간 방출**과 **최종 응답 fold**를 동시에 수행하며 usage를 병합한다.

  SSE/fold/usage/telemetry 버그는 이제 세 곳이 아니라 이 한 곳에서 고친다.
  """

  alias ElGraph.LLM

  @spec chat(module(), atom(), term(), [LLM.message()], keyword()) ::
          {:ok, LLM.response()} | {:error, term()}
  def chat(provider, provider_id, config, messages, opts) do
    req = provider.request_spec(config, messages, opts, :chat)
    req_options = Keyword.get(config, :req_options, [])

    LLM.Telemetry.instrument(provider_id, req.model, fn ->
      case Req.post(
             req.url,
             [json: req.body, headers: req.headers, retry: false] ++ req_options
           ) do
        {:ok, %Req.Response{status: 200, body: body}} -> provider.parse_response(body)
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
        {:error, exception} -> {:error, {:transport_error, exception}}
      end
    end)
  end

  @spec stream_chat(module(), atom(), term(), [LLM.message()], keyword()) ::
          {:ok, LLM.response()} | {:error, term()}
  def stream_chat(provider, provider_id, config, messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    req = provider.request_spec(config, messages, opts, :stream)
    req_options = Keyword.get(config, :req_options, [])

    LLM.Telemetry.instrument(provider_id, req.model, fn ->
      collector = collector(provider, on_delta)

      case Req.post(
             req.url,
             [json: req.body, headers: req.headers, retry: false, into: collector] ++ req_options
           ) do
        {:ok, %Req.Response{status: 200, private: %{el_graph_sse: acc}}} ->
          {:ok, finalize(acc)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, exception} ->
          {:error, {:transport_error, exception}}
      end
    end)
  end

  # Req `into:` 콜렉터 — SSE를 한 번 프레이밍하고, 청크마다 Provider로 delta를 얻어
  # 실시간 방출 + 응답 fold + usage 병합을 누적 상태에 적용한다(원청크 재파싱 없음).
  defp collector(provider, on_delta) do
    fn {:data, data}, {req, resp} ->
      acc = resp.private[:el_graph_sse] || new_acc(provider)
      {payloads, buffer} = LLM.SSE.parse(acc.buffer, data)

      acc =
        payloads
        |> Enum.map(&JSON.decode!/1)
        |> Enum.reduce(%{acc | buffer: buffer}, &absorb(provider, &1, &2, on_delta))

      {:cont, {req, Req.Response.put_private(resp, :el_graph_sse, acc)}}
    end
  end

  defp new_acc(provider) do
    %{
      buffer: "",
      pstate: provider.init_stream_state(),
      content: "",
      tool_order: [],
      tools: %{},
      usage: %{}
    }
  end

  defp absorb(provider, chunk, acc, on_delta) do
    {deltas, pstate} = provider.decode_deltas(chunk, acc.pstate)
    Enum.each(deltas, on_delta)

    acc = Enum.reduce(deltas, %{acc | pstate: pstate}, &fold_delta/2)
    merge_usage(acc, provider.decode_usage(chunk))
  end

  ## delta fold (무손실 문법 → 최종 응답)

  defp fold_delta({:token, text}, acc), do: %{acc | content: acc.content <> text}

  defp fold_delta({:tool_call_start, id, name}, acc) do
    if Map.has_key?(acc.tools, id) do
      acc
    else
      %{
        acc
        | tool_order: acc.tool_order ++ [id],
          tools: Map.put(acc.tools, id, %{id: id, name: name, args: ""})
      }
    end
  end

  defp fold_delta({:tool_call_delta, id, frag}, acc) do
    case acc.tools[id] do
      nil -> acc
      tc -> %{acc | tools: Map.put(acc.tools, id, %{tc | args: tc.args <> frag})}
    end
  end

  defp fold_delta({:tool_call_end, _id}, acc), do: acc

  defp merge_usage(acc, nil), do: acc
  defp merge_usage(acc, partial), do: %{acc | usage: Map.merge(acc.usage, partial)}

  defp finalize(acc) do
    content = if acc.content == "", do: nil, else: acc.content

    tool_calls =
      Enum.map(acc.tool_order, fn id ->
        tc = acc.tools[id]
        %{id: tc.id, name: tc.name, args: JSON.decode!(tc.args)}
      end)

    %{message: LLM.assistant(content, tool_calls), usage: build_usage(acc.usage)}
  end

  # usage는 청크별 부분 병합 결과 — 한 필드라도 봤으면 누락분은 0, 아무것도 없으면 nil.
  defp build_usage(usage) when map_size(usage) == 0, do: nil

  defp build_usage(usage),
    do: %{input_tokens: usage[:input_tokens] || 0, output_tokens: usage[:output_tokens] || 0}
end
