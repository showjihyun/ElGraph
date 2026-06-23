defmodule ElGraph.LLM.ReqLLM do
  @moduledoc """
  [ReqLLM](https://hex.pm/packages/req_llm) 어댑터 — 하나의 어댑터로 ~21개 프로바이더 /
  1000+ 모델(OpenAI·Anthropic·Google·Groq·xAI·OpenRouter·…)에 붙는다.

  **`el_graph_req_llm` 앱이 제공한다** — 코어 `el_graph`는 req_llm을 모른다. 이 앱을 의존성으로
  추가하면 어댑터를 쓸 수 있다(`{:el_graph_req_llm, ...}`).

  config(keyword):

    * `:model`(필수) — ReqLLM 모델 스펙 문자열, 예: `"openai:gpt-4o"` / `"anthropic:claude-haiku-4-5"`
    * `:api_key` — 미지정 시 ReqLLM의 표준 출처(app config / 환경변수 `*_API_KEY`)에서 로드
    * `:req_llm_options` — `ReqLLM.generate_text/3`에 그대로 전달할 추가 옵션

      llm = {ElGraph.LLM.ReqLLM, model: "openai:gpt-4o", api_key: System.fetch_env!("OPENAI_API_KEY")}
      graph = ElGraph.Presets.react(llm, [MyApp.SearchAction])

  툴 실행은 ElGraph(Action 머신)가 담당하므로 ReqLLM tool의 `:callback`은 no-op이다 —
  어댑터는 모델에 tool 스펙을 보내고 돌아온 tool_calls를 ElGraph 메시지로 옮기기만 한다.

  ## 스트리밍 (비지원 — 명시적 폴백)

  이 어댑터는 **비스트리밍 `chat/3`만 구현한다**. 선택 콜백 `stream_chat/3`은 구현하지 않으므로
  `ElGraph.LLM.stream_supported?/1`이 이 어댑터에 대해 `false`를 돌려준다. 스트리밍이 필요한 노드는
  반드시 먼저 `stream_supported?/1`로 확인하고, 미지원이면 `chat/3`(전체 응답을 한 번에 반환)으로
  폴백한다 — `mod.stream_chat/3`을 무조건 호출하면 `UndefinedFunctionError`가 난다.

      {:ok, %{message: msg}} =
        if ElGraph.LLM.stream_supported?(llm),
          do: ElGraph.LLM.stream_to_ctx(llm, messages, opts, ctx),
          else: apply(elem(llm, 0), :chat, [elem(llm, 1), messages, opts])

  토큰 단위 네이티브 SSE 스트리밍이 필요하면 `ElGraph.LLM.{OpenAI, Anthropic, Gemini}` 어댑터를 쓴다.
  """

  @behaviour ElGraph.LLM

  alias ElGraph.LLM
  alias ReqLLM.{Context, Response}

  @impl ElGraph.LLM
  def chat(config, messages, opts) do
    model = Keyword.fetch!(config, :model)

    with {:ok, context} <- encode_context(messages, opts) do
      req_opts = build_opts(config, opts)

      ElGraph.LLM.Telemetry.instrument(:req_llm, model, fn ->
        case ReqLLM.generate_text(model, context, req_opts) do
          {:ok, %Response{} = response} -> decode_response(response)
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @doc false
  def encode_context(messages, opts) do
    system =
      case Keyword.get(opts, :system) do
        nil -> []
        prompt -> [Context.system(prompt)]
      end

    with {:ok, encoded} <- encode_messages(messages) do
      {:ok, Context.new(system ++ encoded)}
    end
  end

  # 메시지를 하나라도 인코딩 못 하면 {:error}로 멈춘다 — 형태가 어긋난 메시지에 chat이
  # FunctionClauseError로 크래시하지 않고 {:error}를 반환하도록(behaviour 계약).
  defp encode_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case encode_message(message) do
        {:error, _reason} = error -> {:halt, error}
        encoded -> {:cont, {:ok, acc ++ [encoded]}}
      end
    end)
  end

  defp encode_message(%{role: :user, content: content}), do: Context.user(content)
  defp encode_message(%{role: :system, content: content}), do: Context.system(content)

  defp encode_message(%{role: :assistant} = message) do
    case message[:tool_calls] || [] do
      [] ->
        Context.assistant(message[:content] || "")

      calls ->
        if Enum.all?(calls, &valid_tool_call?/1) do
          tool_calls = Enum.map(calls, fn call -> {call.name, call.args, id: call.id} end)
          Context.assistant(message[:content] || "", tool_calls: tool_calls)
        else
          {:error, {:invalid_message, message}}
        end
    end
  end

  defp encode_message(%{role: :tool, tool_call_id: id, name: name, content: content}),
    do: Context.tool_result(id, name, content)

  defp encode_message(other), do: {:error, {:invalid_message, other}}

  defp valid_tool_call?(%{name: _, args: _, id: _}), do: true
  defp valid_tool_call?(_), do: false

  @doc false
  def encode_tools(nil), do: nil
  def encode_tools([]), do: nil

  def encode_tools(specs) do
    Enum.map(specs, fn spec ->
      ReqLLM.tool(
        name: spec.name,
        description: spec.description,
        parameter_schema: spec.input_schema,
        # ElGraph가 tool 실행을 담당한다 — ReqLLM은 호출하지 않는다(required 필드라 no-op).
        callback: fn _args -> {:ok, nil} end
      )
    end)
  end

  @doc false
  def decode_response(%Response{} = response) do
    classified = Response.classify(response)
    content = if classified.text == "", do: nil, else: classified.text

    tool_calls =
      Enum.map(classified.tool_calls, fn call ->
        %{id: call.id, name: call.name, args: call.arguments}
      end)

    {:ok, %{message: LLM.assistant(content, tool_calls), usage: decode_usage(response)}}
  end

  defp decode_usage(response) do
    case Response.usage(response) do
      usage when is_map(usage) ->
        %{
          input_tokens: Map.get(usage, :input_tokens, 0),
          output_tokens: Map.get(usage, :output_tokens, 0)
        }

      _missing ->
        nil
    end
  end

  defp build_opts(config, opts) do
    []
    |> put_present(:api_key, Keyword.get(config, :api_key))
    |> put_present(:tools, encode_tools(Keyword.get(opts, :tools)))
    |> Keyword.merge(Keyword.get(config, :req_llm_options, []))
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end
