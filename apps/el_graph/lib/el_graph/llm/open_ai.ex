defmodule ElGraph.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API 어댑터 (비스트리밍).

  config: `:api_key`(필수), `:model`(기본 gpt-4o), `:req_options`.
  어댑터는 자체 재시도를 하지 않는다 — 노드 `retry:` 정책이 담당한다.
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
