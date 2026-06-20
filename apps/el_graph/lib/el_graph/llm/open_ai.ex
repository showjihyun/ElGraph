defmodule ElGraph.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API 어댑터. 전송·SSE·fold·usage·telemetry는 `ElGraph.LLM.Driver`가
  맡고, 이 모듈은 OpenAI 고유의 요청 형태·응답 파싱·청크 디코딩만 공급한다.

  config: `:api_key`(필수), `:model`(기본 gpt-4o), `:req_options`.
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM
  @behaviour ElGraph.LLM.Provider

  alias ElGraph.LLM
  alias ElGraph.LLM.Driver

  @url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o"

  @impl ElGraph.LLM
  def chat(config, messages, opts), do: Driver.chat(__MODULE__, :openai, config, messages, opts)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts),
    do: Driver.stream_chat(__MODULE__, :openai, config, messages, opts)

  ## Provider 매핑 — 진짜 가변인 것만

  @impl ElGraph.LLM.Provider
  def request_spec(config, messages, opts, mode) do
    model = Keyword.get(config, :model, @default_model)

    system_messages =
      case Keyword.get(opts, :system) do
        nil -> []
        system -> [%{role: "system", content: system}]
      end

    body =
      %{model: model, messages: system_messages ++ Enum.map(messages, &encode_message/1)}
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))
      |> stream_body(mode)

    %{
      url: @url,
      headers: [{"authorization", "Bearer #{Keyword.fetch!(config, :api_key)}"}],
      body: body,
      model: model
    }
  end

  defp stream_body(body, :stream),
    do: body |> Map.put(:stream, true) |> Map.put(:stream_options, %{include_usage: true})

  defp stream_body(body, :chat), do: body

  @impl ElGraph.LLM.Provider
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

  ## 스트림 청크 디코딩 (delta + usage)

  @impl ElGraph.LLM.Provider
  def init_stream_state, do: %{tool_index_to_id: %{}}

  # 한 청크에서 토큰·tool-call delta·완료(end)를 순서대로 디코딩한다. tool-call 인자 조각은
  # index만 싣고 id는 첫 청크에만 오므로 index→id 상태를 청크 간에 잇는다.
  @impl ElGraph.LLM.Provider
  def decode_deltas(%{"choices" => [%{"delta" => delta} = choice | _]}, state) do
    {tool_deltas, state} =
      Enum.reduce(delta["tool_calls"] || [], {[], state}, fn call, {acc, st} ->
        {more, st} = tool_call_deltas(call, st)
        {acc ++ more, st}
      end)

    deltas = token_deltas(delta["content"]) ++ tool_deltas ++ finish_deltas(choice, state)
    {deltas, state}
  end

  def decode_deltas(_chunk, state), do: {[], state}

  defp token_deltas(content) when is_binary(content) and content != "", do: [{:token, content}]
  defp token_deltas(_content), do: []

  defp tool_call_deltas(%{"index" => index, "id" => id} = call, state) when is_binary(id) do
    {start, state} =
      if Map.has_key?(state.tool_index_to_id, index) do
        {[], state}
      else
        {[{:tool_call_start, id, call["function"]["name"]}],
         put_in(state.tool_index_to_id[index], id)}
      end

    {start ++ arg_deltas(call, index, state), state}
  end

  defp tool_call_deltas(%{"index" => index} = call, state) do
    {arg_deltas(call, index, state), state}
  end

  defp arg_deltas(call, index, state) do
    case call["function"]["arguments"] do
      frag when is_binary(frag) and frag != "" ->
        [{:tool_call_delta, state.tool_index_to_id[index], frag}]

      _empty ->
        []
    end
  end

  defp finish_deltas(%{"finish_reason" => "tool_calls"}, state),
    do: for({_index, id} <- state.tool_index_to_id, do: {:tool_call_end, id})

  defp finish_deltas(_choice, _state), do: []

  @impl ElGraph.LLM.Provider
  def decode_usage(%{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}}),
    do: %{input_tokens: input, output_tokens: output}

  def decode_usage(_chunk), do: nil

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
