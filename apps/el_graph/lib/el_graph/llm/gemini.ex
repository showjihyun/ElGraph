defmodule ElGraph.LLM.Gemini do
  @moduledoc """
  Google Gemini generateContent API 어댑터 (`chat/3` 비스트리밍 + `stream_chat/3` SSE 스트리밍).

  config: `:api_key`(필수), `:model`(기본 gemini-2.5-flash), `:req_options`.
  Gemini는 tool call id가 없어 이름으로 매칭한다 — 중립 메시지의 `id`에 툴 이름이
  들어가며, 같은 superstep에서 동일 툴의 중복 호출은 구분되지 않는다.
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
  """

  @behaviour ElGraph.LLM

  alias ElGraph.LLM

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-2.5-flash"

  @impl ElGraph.LLM
  def chat(config, messages, opts) do
    request = build_request(config, messages, opts)
    req_options = Keyword.get(config, :req_options, [])
    model = Keyword.get(config, :model, @default_model)

    ElGraph.LLM.Telemetry.instrument(:gemini, model, fn ->
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

    system_parts =
      [Keyword.get(opts, :system) | Enum.map(system_messages, & &1.content)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{text: &1})

    body =
      %{contents: Enum.map(conversation, &encode_message/1)}
      |> put_present(:systemInstruction, if(system_parts != [], do: %{parts: system_parts}))
      |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))

    model = Keyword.get(config, :model, @default_model)

    %{
      url: "#{@base_url}/#{model}:generateContent",
      headers: [{"x-goog-api-key", Keyword.fetch!(config, :api_key)}],
      body: body
    }
  end

  @doc false
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

  ## 스트리밍 (SSE)

  @impl ElGraph.LLM
  def stream_chat(config, messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    request = build_request(config, messages, opts)
    model = Keyword.get(config, :model, @default_model)
    url = "#{@base_url}/#{model}:streamGenerateContent?alt=sse"
    req_options = Keyword.get(config, :req_options, [])

    ElGraph.LLM.Telemetry.instrument(:gemini, model, fn ->
      collector = stream_collector(on_delta)

      result =
        Req.post(
          url,
          [json: request.body, headers: request.headers, retry: false, into: collector] ++
            req_options
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
  def decode_deltas(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    for %{"text" => text} <- parts, is_binary(text) and text != "", do: {:token, text}
  end

  def decode_deltas(_chunk), do: []

  @doc false
  @spec reduce_chunks([map()]) :: {:ok, ElGraph.LLM.response()}
  def reduce_chunks(chunks) do
    acc = Enum.reduce(chunks, %{content: "", tool_calls: [], usage: nil}, &reduce_chunk/2)

    content = if acc.content == "", do: nil, else: acc.content
    {:ok, %{message: LLM.assistant(content, Enum.reverse(acc.tool_calls)), usage: acc.usage}}
  end

  defp reduce_chunk(chunk, acc) do
    acc
    |> accumulate_parts(get_in(chunk, ["candidates", Access.at(0), "content", "parts"]))
    |> accumulate_usage(chunk["usageMetadata"])
  end

  defp accumulate_parts(acc, nil), do: acc

  defp accumulate_parts(acc, parts) do
    Enum.reduce(parts, acc, fn
      %{"text" => text}, acc when is_binary(text) ->
        %{acc | content: acc.content <> text}

      %{"functionCall" => call}, acc ->
        tc = %{id: call["name"], name: call["name"], args: call["args"] || %{}}
        %{acc | tool_calls: [tc | acc.tool_calls]}

      _part, acc ->
        acc
    end)
  end

  defp accumulate_usage(acc, %{"promptTokenCount" => input, "candidatesTokenCount" => output}),
    do: %{acc | usage: %{input_tokens: input, output_tokens: output}}

  defp accumulate_usage(acc, _missing), do: acc

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
