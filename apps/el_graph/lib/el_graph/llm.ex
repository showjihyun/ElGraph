defmodule ElGraph.LLM do
  @moduledoc """
  LLM 클라이언트 behaviour (SPEC §4). 코어는 LLM을 모른다 — 어댑터는 이 표면만 구현한다.

  메시지는 프로바이더 중립 맵이다:

    * `%{role: :user | :system, content: binary}`
    * `%{role: :assistant, content: binary | nil, tool_calls: [tool_call]}`
    * `%{role: :tool, tool_call_id: id, name: name, content: term}`

  실제 프로바이더 어댑터(Anthropic/OpenAI, Req + SSE)는 별도 패키지 `el_graph_llm`.
  테스트에는 `ElGraph.Test.ScriptedLLM`을 쓴다.
  """

  @type message :: map()
  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}
  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
  @type response :: %{message: message(), usage: usage() | nil}

  @doc """
  대화를 모델에 보내고 다음 assistant 메시지를 받는다.

  `opts`: `:tools`(tool 스펙 목록 — `ElGraph.Action.to_tool_spec/1` 형태),
  `:system` 등 어댑터별 옵션.
  """
  @callback chat(config :: term(), messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @typedoc "스트리밍 델타 이벤트 — `on_delta` 콜백이 받는다."
  @type delta :: {:token, binary()}

  @doc """
  `chat/3`의 스트리밍 변형. 토큰이 도착하는 대로 `opts[:on_delta]`(`delta()` 1-인자 fun)를
  호출하고, 완료 시 `chat/3`과 동일한 누적 `response()`를 반환한다. 선택 콜백 — 모든
  어댑터가 구현하지는 않는다(`stream_supported?/1`로 확인).
  """
  @callback stream_chat(config :: term(), messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @optional_callbacks stream_chat: 3

  @doc "어댑터(`{module, config}`)가 스트리밍(`stream_chat/3`)을 지원하는지 확인한다."
  @spec stream_supported?({module(), term()}) :: boolean()
  def stream_supported?({module, _config}) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :stream_chat, 3)
  end

  @doc "usage 누적 reducer — `:usage` 채널에 쓴다 (비용 가드, SPEC §4)."
  @spec add_usage(usage(), usage() | nil) :: usage()
  def add_usage(current, nil), do: current

  def add_usage(current, new) when is_map(current) and is_map(new) do
    %{
      input_tokens: current.input_tokens + Map.get(new, :input_tokens, 0),
      output_tokens: current.output_tokens + Map.get(new, :output_tokens, 0)
    }
  end

  ## 메시지 생성 헬퍼

  @spec user(binary()) :: message()
  def user(content), do: %{role: :user, content: content}

  @spec assistant(binary() | nil, [tool_call()]) :: message()
  def assistant(content, tool_calls \\ []),
    do: %{role: :assistant, content: content, tool_calls: tool_calls}

  @spec tool_call(String.t(), String.t(), map()) :: tool_call()
  def tool_call(id, name, args), do: %{id: id, name: name, args: args}

  @spec tool_result(String.t(), String.t(), term()) :: message()
  def tool_result(tool_call_id, name, content),
    do: %{role: :tool, tool_call_id: tool_call_id, name: name, content: content}
end
