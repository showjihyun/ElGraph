defmodule ElGraph.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API 어댑터 (`chat/3` 비스트리밍 + `stream_chat/3` SSE 스트리밍).

      llm = {ElGraph.LLM.Anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY")}
      graph = ElGraph.Presets.react(llm, tools)

  config: `:api_key`(필수), `:model`(기본 claude-sonnet-4-6), `:max_tokens`,
  `:req_options`(테스트용 plug 등 — `Req.post` 옵션에 병합).
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM

  alias ElGraph.LLM

  @url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096

  @impl ElGraph.LLM
  def chat(config, messages, opts) do
    request = build_request(config, messages, opts)
    req_options = Keyword.get(config, :req_options, [])

    ElGraph.LLM.Telemetry.instrument(:anthropic, request.body.model, fn ->
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
    {system_messages, conversation} = Enum.split_with(messages, &(&1.role == :system))

    system =
      [Keyword.get(opts, :system) | Enum.map(system_messages, & &1.content)]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    body =
      %{
        model: Keyword.get(config, :model, @default_model),
        max_tokens: Keyword.get(config, :max_tokens, @default_max_tokens),
        messages: Enum.map(conversation, &encode_message/1)
      }
      |> put_present(:system, system)
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))

    %{
      url: @url,
      headers: [
        {"x-api-key", Keyword.fetch!(config, :api_key)},
        {"anthropic-version", "2023-06-01"}
      ],
      body: body
    }
  end

  @doc false
  def parse_response(%{"content" => blocks} = body) do
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    tool_calls =
      for %{"type" => "tool_use"} = block <- blocks do
        %{id: block["id"], name: block["name"], args: block["input"]}
      end

    usage =
      case body["usage"] do
        %{"input_tokens" => input, "output_tokens" => output} ->
          %{input_tokens: input, output_tokens: output}

        _missing ->
          nil
      end

    content = if text == "", do: nil, else: text
    {:ok, %{message: LLM.assistant(content, tool_calls), usage: usage}}
  end

  def parse_response(other), do: {:error, {:unexpected_response, other}}

  ## 스트리밍 (SSE)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    request = build_request(config, messages, opts)
    body = Map.put(request.body, :stream, true)
    req_options = Keyword.get(config, :req_options, [])

    ElGraph.LLM.Telemetry.instrument(:anthropic, body.model, fn ->
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

  # Req `into:` 콜렉터 — SSE 청크를 파싱하고 델타를 실시간 방출, 원청크는 누적한다.
  # 증분 tool-call 방출을 위해 인덱스→id 상태(`stream_acc`)를 청크 간에 잇는다.
  defp stream_collector(on_delta) do
    fn {:data, data}, {req, resp} ->
      state =
        resp.private[:el_graph_sse] || %{buffer: "", chunks: [], stream_acc: new_stream_acc()}

      {payloads, buffer} = ElGraph.LLM.SSE.parse(state.buffer, data)
      decoded = Enum.map(payloads, &JSON.decode!/1)
      stream_acc = Enum.reduce(decoded, state.stream_acc, &stream_step(&1, &2, on_delta))
      state = %{buffer: buffer, chunks: state.chunks ++ decoded, stream_acc: stream_acc}
      {:cont, {req, Req.Response.put_private(resp, :el_graph_sse, state)}}
    end
  end

  @doc false
  @spec new_stream_acc() :: map()
  def new_stream_acc, do: %{tool_index_to_id: %{}}

  @doc false
  @spec stream_step(map(), map(), (ElGraph.LLM.delta() -> any())) :: map()
  def stream_step(
        %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
        acc,
        on_delta
      )
      when is_binary(text) and text != "" do
    on_delta.({:token, text})
    acc
  end

  def stream_step(
        %{
          "type" => "content_block_start",
          "index" => index,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
        },
        acc,
        on_delta
      ) do
    on_delta.({:tool_call_start, id, name})
    put_in(acc.tool_index_to_id[index], id)
  end

  def stream_step(
        %{
          "type" => "content_block_delta",
          "index" => index,
          "delta" => %{"type" => "input_json_delta", "partial_json" => frag}
        },
        acc,
        on_delta
      )
      when is_binary(frag) and frag != "" do
    emit_tool_delta(acc.tool_index_to_id[index], frag, on_delta)
    acc
  end

  def stream_step(%{"type" => "content_block_stop", "index" => index}, acc, on_delta) do
    case acc.tool_index_to_id[index] do
      nil -> :ok
      id -> on_delta.({:tool_call_end, id})
    end

    acc
  end

  def stream_step(_chunk, acc, _on_delta), do: acc

  defp emit_tool_delta(nil, _frag, _on_delta), do: :ok
  defp emit_tool_delta(id, frag, on_delta), do: on_delta.({:tool_call_delta, id, frag})

  @doc false
  @spec decode_deltas(map()) :: [ElGraph.LLM.delta()]
  def decode_deltas(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text}
      })
      when is_binary(text) and text != "",
      do: [{:token, text}]

  def decode_deltas(_chunk), do: []

  @doc false
  @spec reduce_chunks([map()]) :: {:ok, ElGraph.LLM.response()}
  def reduce_chunks(chunks) do
    acc =
      Enum.reduce(
        chunks,
        %{content: "", tools: %{}, input: nil, output: nil},
        &reduce_chunk/2
      )

    tool_calls =
      acc.tools
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, tc} ->
        %{id: tc.id, name: tc.name, args: JSON.decode!(tc.args)}
      end)

    content = if acc.content == "", do: nil, else: acc.content
    usage = build_usage(acc.input, acc.output)
    {:ok, %{message: LLM.assistant(content, tool_calls), usage: usage}}
  end

  defp reduce_chunk(
         %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => input}}},
         acc
       ),
       do: %{acc | input: input}

  defp reduce_chunk(%{"type" => "message_delta", "usage" => %{"output_tokens" => output}}, acc),
    do: %{acc | output: output}

  defp reduce_chunk(
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
         },
         acc
       ),
       do: %{acc | tools: Map.put(acc.tools, index, %{id: id, name: name, args: ""})}

  defp reduce_chunk(
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => text}
         },
         acc
       ),
       do: %{acc | content: acc.content <> text}

  defp reduce_chunk(
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial}
         },
         acc
       ) do
    existing = Map.get(acc.tools, index, %{id: nil, name: nil, args: ""})
    %{acc | tools: Map.put(acc.tools, index, %{existing | args: existing.args <> partial})}
  end

  defp reduce_chunk(_chunk, acc), do: acc

  defp build_usage(nil, nil), do: nil
  defp build_usage(input, output), do: %{input_tokens: input || 0, output_tokens: output || 0}

  ## 메시지 변환

  defp encode_message(%{role: :user, content: content}), do: %{role: "user", content: content}

  defp encode_message(%{role: :assistant} = message) do
    text_blocks =
      case message[:content] do
        nil -> []
        text -> [%{type: "text", text: text}]
      end

    tool_blocks =
      for call <- message[:tool_calls] || [] do
        %{type: "tool_use", id: call.id, name: call.name, input: call.args}
      end

    %{role: "assistant", content: text_blocks ++ tool_blocks}
  end

  defp encode_message(%{role: :tool} = message) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: message.tool_call_id,
          content: stringify(message.content)
        }
      ]
    }
  end

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn spec ->
      %{name: spec.name, description: spec.description, input_schema: spec.input_schema}
    end)
  end

  defp stringify(content) when is_binary(content), do: content
  defp stringify(content), do: JSON.encode!(content)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
