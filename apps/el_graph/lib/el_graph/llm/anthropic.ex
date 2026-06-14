defmodule ElGraph.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API 어댑터 (비스트리밍).

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
