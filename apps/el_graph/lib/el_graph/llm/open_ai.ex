defmodule ElGraph.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API 어댑터 (`chat/3` 비스트리밍 + `stream_chat/3` SSE 스트리밍).

  config: `:api_key`(필수), `:model`(기본 gpt-4o), `:req_options`.
  `stream_chat/3`은 `opts[:on_delta]`로 토큰을 실시간 방출하고 완료 시 `chat/3`과 동일한
  누적 응답을 반환한다. 어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM

  alias ElGraph.LLM

  @url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o"

  @impl ElGraph.LLM
  def chat(config, messages, opts) do
    request = build_request(config, messages, opts)
    req_options = Keyword.get(config, :req_options, [])

    ElGraph.LLM.Telemetry.instrument(:openai, request.body.model, fn ->
      case Req.post(
             request.url,
             [json: request.body, headers: request.headers, retry: false] ++ req_options
           ) do
        {:ok, %Req.Response{status: 200, body: body}} -> parse_response(body)
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
        {:error, exception} -> {:error, {:transport_error, exception}}
      end
    end)
  end

  @doc false
  def build_request(config, messages, opts) do
    system_messages =
      case Keyword.get(opts, :system) do
        nil -> []
        system -> [%{role: "system", content: system}]
      end

    body =
      %{
        model: Keyword.get(config, :model, @default_model),
        messages: system_messages ++ Enum.map(messages, &encode_message/1)
      }
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))

    %{
      url: @url,
      headers: [{"authorization", "Bearer #{Keyword.fetch!(config, :api_key)}"}],
      body: body
    }
  end

  @doc false
  def parse_response(%{"choices" => [%{"message" => message} | _rest]} = body) do
    tool_calls =
      for call <- message["tool_calls"] || [] do
        %{
          id: call["id"],
          name: call["function"]["name"],
          args: JSON.decode!(call["function"]["arguments"])
        }
      end

    usage =
      case body["usage"] do
        %{"prompt_tokens" => input, "completion_tokens" => output} ->
          %{input_tokens: input, output_tokens: output}

        _missing ->
          nil
      end

    {:ok, %{message: LLM.assistant(message["content"], tool_calls), usage: usage}}
  end

  def parse_response(other), do: {:error, {:unexpected_response, other}}

  ## 스트리밍 (SSE)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    request = build_request(config, messages, opts)

    body =
      request.body
      |> Map.put(:stream, true)
      |> Map.put(:stream_options, %{include_usage: true})

    req_options = Keyword.get(config, :req_options, [])

    ElGraph.LLM.Telemetry.instrument(:openai, body.model, fn ->
      collector = stream_collector(on_delta)

      result =
        Req.post(
          request.url,
          [json: body, headers: request.headers, retry: false, into: collector] ++ req_options
        )

      case result do
        {:ok, %Req.Response{status: 200, private: %{el_graph_sse: %{chunks: chunks}}}} ->
          reduce_chunks(chunks)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, exception} ->
          {:error, {:transport_error, exception}}
      end
    end)
  end

  # Req `into:` 콜렉터 — SSE 청크를 파싱하고 토큰을 실시간 방출, 원청크는 누적한다.
  defp stream_collector(on_delta) do
    fn {:data, data}, {req, resp} ->
      state = resp.private[:el_graph_sse] || %{buffer: "", chunks: []}
      {payloads, buffer} = ElGraph.LLM.SSE.parse(state.buffer, data)
      decoded = Enum.map(payloads, &JSON.decode!/1)
      Enum.each(decoded, fn chunk -> Enum.each(decode_deltas(chunk), on_delta) end)
      state = %{buffer: buffer, chunks: state.chunks ++ decoded}
      {:cont, {req, Req.Response.put_private(resp, :el_graph_sse, state)}}
    end
  end

  @doc false
  @spec decode_deltas(map()) :: [ElGraph.LLM.delta()]
  def decode_deltas(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
      when is_binary(content) and content != "",
      do: [{:token, content}]

  def decode_deltas(_chunk), do: []

  @doc false
  @spec reduce_chunks([map()]) :: {:ok, ElGraph.LLM.response()}
  def reduce_chunks(chunks) do
    acc = Enum.reduce(chunks, %{content: "", tools: %{}, usage: nil}, &reduce_chunk/2)

    tool_calls =
      acc.tools
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, tc} ->
        %{id: tc.id, name: tc.name, args: JSON.decode!(tc.args)}
      end)

    content = if acc.content == "", do: nil, else: acc.content
    {:ok, %{message: LLM.assistant(content, tool_calls), usage: acc.usage}}
  end

  defp reduce_chunk(
         %{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}},
         acc
       ),
       do: %{acc | usage: %{input_tokens: input, output_tokens: output}}

  defp reduce_chunk(%{"choices" => [%{"delta" => delta} | _]}, acc) do
    acc
    |> accumulate_content(delta["content"])
    |> accumulate_tool_calls(delta["tool_calls"])
  end

  defp reduce_chunk(_chunk, acc), do: acc

  defp accumulate_content(acc, nil), do: acc
  defp accumulate_content(acc, text), do: %{acc | content: acc.content <> text}

  defp accumulate_tool_calls(acc, nil), do: acc

  defp accumulate_tool_calls(acc, calls) do
    tools =
      Enum.reduce(calls, acc.tools, fn call, tools ->
        index = call["index"]
        existing = Map.get(tools, index, %{id: nil, name: nil, args: ""})

        updated = %{
          id: call["id"] || existing.id,
          name: call["function"]["name"] || existing.name,
          args: existing.args <> (call["function"]["arguments"] || "")
        }

        Map.put(tools, index, updated)
      end)

    %{acc | tools: tools}
  end

  ## 메시지 변환

  defp encode_message(%{role: :system, content: content}),
    do: %{role: "system", content: content}

  defp encode_message(%{role: :user, content: content}), do: %{role: "user", content: content}

  defp encode_message(%{role: :assistant} = message) do
    base = %{role: "assistant", content: message[:content]}

    case message[:tool_calls] || [] do
      [] ->
        base

      calls ->
        encoded =
          for call <- calls do
            %{
              id: call.id,
              type: "function",
              function: %{name: call.name, arguments: JSON.encode!(call.args)}
            }
          end

        Map.put(base, :tool_calls, encoded)
    end
  end

  defp encode_message(%{role: :tool} = message) do
    %{role: "tool", tool_call_id: message.tool_call_id, content: stringify(message.content)}
  end

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn spec ->
      %{
        type: "function",
        function: %{
          name: spec.name,
          description: spec.description,
          parameters: spec.input_schema
        }
      }
    end)
  end

  defp stringify(content) when is_binary(content), do: content
  defp stringify(content), do: JSON.encode!(content)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
