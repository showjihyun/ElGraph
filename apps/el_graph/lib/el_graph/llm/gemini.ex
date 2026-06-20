defmodule ElGraph.LLM.Gemini do
  @moduledoc """
  Google Gemini generateContent API 어댑터. 전송·SSE·fold·usage·telemetry는
  `ElGraph.LLM.Driver`가 맡고, 이 모듈은 Gemini 고유의 요청 형태·응답 파싱·청크 디코딩만 공급한다.

  config: `:api_key`(필수), `:model`(기본 gemini-2.5-flash), `:req_options`.
  Gemini는 tool call id가 없어 이름으로 매칭한다 — 중립 메시지의 `id`에 툴 이름이 들어가며,
  같은 superstep에서 동일 툴의 중복 호출은 구분되지 않는다.
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM
  @behaviour ElGraph.LLM.Provider

  alias ElGraph.LLM
  alias ElGraph.LLM.Driver

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-2.5-flash"

  @impl ElGraph.LLM
  def chat(config, messages, opts), do: Driver.chat(__MODULE__, :gemini, config, messages, opts)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts),
    do: Driver.stream_chat(__MODULE__, :gemini, config, messages, opts)

  ## Provider 매핑 — 진짜 가변인 것만 (스트림은 body가 아니라 URL이 바뀐다)

  @impl ElGraph.LLM.Provider
  def request_spec(config, messages, opts, mode) do
    model = Keyword.get(config, :model, @default_model)
    {system_messages, conversation} = Enum.split_with(messages, &(&1.role == :system))

    system_parts =
      [Keyword.get(opts, :system) | Enum.map(system_messages, & &1.content)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{text: &1})

    body =
      %{contents: Enum.map(conversation, &encode_message/1)}
      |> put_present(:systemInstruction, if(system_parts != [], do: %{parts: system_parts}))
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))

    %{
      url: "#{@base_url}/#{model}:#{endpoint(mode)}",
      headers: [{"x-goog-api-key", Keyword.fetch!(config, :api_key)}],
      body: body,
      model: model
    }
  end

  defp endpoint(:stream), do: "streamGenerateContent?alt=sse"
  defp endpoint(:chat), do: "generateContent"

  @impl ElGraph.LLM.Provider
  def parse_response(%{"candidates" => [%{"content" => %{"parts" => parts}} | _rest]} = body) do
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map_join("", & &1["text"])

    tool_calls =
      for %{"functionCall" => call} <- parts do
        %{id: call["name"], name: call["name"], args: call["args"]}
      end

    usage =
      case body["usageMetadata"] do
        %{"promptTokenCount" => input, "candidatesTokenCount" => output} ->
          %{input_tokens: input, output_tokens: output}

        _missing ->
          nil
      end

    content = if text == "", do: nil, else: text
    {:ok, %{message: LLM.assistant(content, tool_calls), usage: usage}}
  end

  def parse_response(other), do: {:error, {:unexpected_response, other}}

  ## 스트림 청크 디코딩 (delta + usage)

  # Gemini는 functionCall을 한 청크에 완결로 보내므로 무상태다 — start/delta/end를 합성해
  # 다른 어댑터와 동일한 delta 문법으로 노출한다(id=툴 이름, parse_response/1과 일관).
  @impl ElGraph.LLM.Provider
  def init_stream_state, do: %{}

  @impl ElGraph.LLM.Provider
  def decode_deltas(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}, state) do
    {Enum.flat_map(parts, &part_deltas/1), state}
  end

  def decode_deltas(_chunk, state), do: {[], state}

  defp part_deltas(%{"text" => text}) when is_binary(text) and text != "", do: [{:token, text}]

  defp part_deltas(%{"functionCall" => call}) do
    name = call["name"]

    [
      {:tool_call_start, name, name},
      {:tool_call_delta, name, JSON.encode!(call["args"] || %{})},
      {:tool_call_end, name}
    ]
  end

  defp part_deltas(_part), do: []

  @impl ElGraph.LLM.Provider
  def decode_usage(%{
        "usageMetadata" => %{"promptTokenCount" => input, "candidatesTokenCount" => output}
      }),
      do: %{input_tokens: input, output_tokens: output}

  def decode_usage(_chunk), do: nil

  ## 메시지 변환

  defp encode_message(%{role: :user, content: content}),
    do: %{role: "user", parts: [%{text: content}]}

  defp encode_message(%{role: :assistant} = message) do
    text_parts =
      case message[:content] do
        nil -> []
        text -> [%{text: text}]
      end

    call_parts =
      for call <- message[:tool_calls] || [] do
        %{functionCall: %{name: call.name, args: call.args}}
      end

    %{role: "model", parts: text_parts ++ call_parts}
  end

  defp encode_message(%{role: :tool} = message) do
    %{
      role: "user",
      parts: [
        %{
          functionResponse: %{
            name: message.name,
            response: %{content: stringify(message.content)}
          }
        }
      ]
    }
  end

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    declarations =
      Enum.map(tools, fn spec ->
        %{name: spec.name, description: spec.description, parameters: spec.input_schema}
      end)

    [%{functionDeclarations: declarations}]
  end

  defp stringify(content) when is_binary(content), do: content
  defp stringify(content), do: JSON.encode!(content)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
