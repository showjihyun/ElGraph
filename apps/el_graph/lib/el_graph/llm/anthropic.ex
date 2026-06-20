defmodule ElGraph.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API 어댑터. 전송·SSE·fold·usage·telemetry는 `ElGraph.LLM.Driver`가
  맡고, 이 모듈은 Anthropic 고유의 요청 형태·응답 파싱·청크 디코딩만 공급한다.

      llm = {ElGraph.LLM.Anthropic, api_key: System.fetch_env!("ANTHROPIC_API_KEY")}
      graph = ElGraph.Presets.react(llm, tools)

  config: `:api_key`(필수), `:model`(기본 claude-sonnet-4-6), `:max_tokens`, `:req_options`.
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM
  @behaviour ElGraph.LLM.Provider

  alias ElGraph.LLM
  alias ElGraph.LLM.Driver

  @url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096

  @impl ElGraph.LLM
  def chat(config, messages, opts),
    do: Driver.chat(__MODULE__, :anthropic, config, messages, opts)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts),
    do: Driver.stream_chat(__MODULE__, :anthropic, config, messages, opts)

  ## Provider 매핑 — 진짜 가변인 것만

  @impl ElGraph.LLM.Provider
  def request_spec(config, messages, opts, mode) do
    model = Keyword.get(config, :model, @default_model)
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
        model: model,
        max_tokens: Keyword.get(config, :max_tokens, @default_max_tokens),
        messages: Enum.map(conversation, &encode_message/1)
      }
      |> put_present(:system, system)
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))
      |> stream_body(mode)

    %{
      url: @url,
      headers: [
        {"x-api-key", Keyword.fetch!(config, :api_key)},
        {"anthropic-version", "2023-06-01"}
      ],
      body: body,
      model: model
    }
  end

  defp stream_body(body, :stream), do: Map.put(body, :stream, true)
  defp stream_body(body, :chat), do: body

  @impl ElGraph.LLM.Provider
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

  ## 스트림 청크 디코딩 (delta + usage)

  @impl ElGraph.LLM.Provider
  def init_stream_state, do: %{tool_index_to_id: %{}}

  @impl ElGraph.LLM.Provider
  def decode_deltas(
        %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
        state
      )
      when is_binary(text) and text != "" do
    {[{:token, text}], state}
  end

  def decode_deltas(
        %{
          "type" => "content_block_start",
          "index" => index,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
        },
        state
      ) do
    {[{:tool_call_start, id, name}], put_in(state.tool_index_to_id[index], id)}
  end

  def decode_deltas(
        %{
          "type" => "content_block_delta",
          "index" => index,
          "delta" => %{"type" => "input_json_delta", "partial_json" => frag}
        },
        state
      )
      when is_binary(frag) and frag != "" do
    case state.tool_index_to_id[index] do
      nil -> {[], state}
      id -> {[{:tool_call_delta, id, frag}], state}
    end
  end

  def decode_deltas(%{"type" => "content_block_stop", "index" => index}, state) do
    case state.tool_index_to_id[index] do
      nil -> {[], state}
      id -> {[{:tool_call_end, id}], state}
    end
  end

  def decode_deltas(_chunk, state), do: {[], state}

  @impl ElGraph.LLM.Provider
  def decode_usage(%{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => i}}
      }),
      do: %{input_tokens: i}

  def decode_usage(%{"type" => "message_delta", "usage" => %{"output_tokens" => o}}),
    do: %{output_tokens: o}

  def decode_usage(_chunk), do: nil

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
