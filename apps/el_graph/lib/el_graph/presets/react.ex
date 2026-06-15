defmodule ElGraph.Presets.ReAct do
  @moduledoc """
  ReAct 프리셋의 노드 구현 (SPEC §4). 모든 노드는 MFA로 그래프에 들어간다.

  흐름: `:agent`(LLM 호출, assistant 메시지 append) → 라우터(tool_calls 있으면
  `:tools`, 없으면 종료) → `:tools`(툴 실행, tool 메시지 append) → `:agent` 반복.

  툴 실패는 복구 가능하게 설계됐다: 알 수 없는 툴 이름(LLM 환각)과 파라미터 검증
  실패는 run을 죽이지 않고 `"error: ..."` tool 메시지로 LLM에게 돌아간다.
  LLM 호출 실패만 `ElGraph.LLMError`로 노드를 crash시킨다 — `retry:` 정책과 결합 지점.
  """

  alias ElGraph.{Action, Ctx, Guardrail, LLM, LLMError, RateLimiter, Reducers}
  alias ElGraph.MCP.Tool, as: MCPTool

  @doc false
  def build(llm, tools, opts) do
    guardrails = Keyword.get(opts, :guardrails, [])

    agent_cfg = %{
      llm: llm,
      tools: tools,
      system: Keyword.get(opts, :system),
      rate_limiter: Keyword.get(opts, :rate_limiter),
      input_guards: Keyword.get(guardrails, :input, []),
      output_guards: Keyword.get(guardrails, :output, [])
    }

    ElGraph.new()
    |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
    |> ElGraph.state(:usage,
      default: %{input_tokens: 0, output_tokens: 0},
      reducer: {LLM, :add_usage, []}
    )
    |> ElGraph.state(:budget, default: get_in(opts, [:budget, :tokens]))
    |> ElGraph.add_node(:agent, {__MODULE__, :agent, [agent_cfg]})
    |> ElGraph.add_node(:tools, {__MODULE__, :run_tools, [tools]})
    |> ElGraph.add_edge(:tools, :agent)
    |> ElGraph.add_conditional_edge(:agent, {__MODULE__, :route, []})
    |> ElGraph.compile(entry: :agent)
  end

  @doc false
  def agent(%{messages: messages} = state, ctx, cfg) do
    # 예산 검사는 LLM 호출 *이전* — 인터럽트 후 재개 시 노드가 처음부터 재실행되므로
    # 호출 이후에 걸면 비싼 호출이 중복된다 (SPEC §3.6 재실행 시맨틱, 부록 A-4).
    budget_update = check_budget(state, ctx)
    {llm_mod, llm_config} = cfg.llm

    chat_opts =
      [tools: Enum.map(cfg.tools, &tool_spec/1)] ++
        if cfg.system, do: [system: cfg.system], else: []

    # 입력 가드: LLM 호출 *이전*. 차단되면 호출하지 않고 거부 메시지로 루프를 끝낸다.
    case guard_input(messages, cfg.input_guards) do
      {:ok, guarded_messages} ->
        # 마찰 6: 모든 LLM 호출은 rate_limiter를 통과한다 (지정 시).
        case call_llm(cfg.rate_limiter, llm_mod, llm_config, guarded_messages, chat_opts) do
          {:ok, %{message: message} = response} ->
            guarded = guard_output(message, cfg.output_guards)
            Map.merge(%{messages: [guarded], usage: Map.get(response, :usage)}, budget_update)

          {:error, reason} ->
            raise LLMError, reason: reason
        end

      {:blocked, reason} ->
        Map.merge(%{messages: [blocked_message(reason)]}, budget_update)
    end
  end

  # 마지막 user 메시지의 binary content에만 입력 가드를 적용한다.
  defp guard_input(messages, []), do: {:ok, messages}

  defp guard_input(messages, guards) do
    case List.last(messages) do
      %{role: :user, content: content} = last when is_binary(content) ->
        case Guardrail.check(guards, content, %{}) do
          {:ok, ^content} -> {:ok, messages}
          {:ok, transformed} -> {:ok, replace_last(messages, %{last | content: transformed})}
          {:blocked, reason} -> {:blocked, reason}
        end

      _other ->
        {:ok, messages}
    end
  end

  # assistant 메시지의 binary content에 출력 가드를 적용한다.
  defp guard_output(message, []), do: message

  defp guard_output(%{content: content} = message, guards) when is_binary(content) do
    case Guardrail.check(guards, content, %{}) do
      {:ok, transformed} -> %{message | content: transformed}
      # tool_calls를 떨궈 route/1이 루프를 안전하게 끝내게 한다.
      {:blocked, reason} -> blocked_message(reason)
    end
  end

  defp guard_output(message, _guards), do: message

  defp blocked_message(reason), do: LLM.assistant("[blocked: #{inspect(reason)}]")

  defp replace_last(messages, new_last),
    do: List.replace_at(messages, length(messages) - 1, new_last)

  defp call_llm(nil, mod, config, messages, opts), do: mod.chat(config, messages, opts)

  defp call_llm(limiter, mod, config, messages, opts) do
    RateLimiter.with_limit(limiter, fn -> mod.chat(config, messages, opts) end)
  end

  defp check_budget(%{budget: nil}, _ctx), do: %{}

  defp check_budget(%{budget: budget, usage: usage}, ctx) do
    if usage.input_tokens + usage.output_tokens >= budget do
      # 사람이 계속/중단을 결정한다 — resume 값이 새 예산이 된다.
      new_budget = Ctx.interrupt(ctx, %{type: :budget_exceeded, budget: budget, usage: usage})
      %{budget: new_budget}
    else
      %{}
    end
  end

  @doc false
  def route(%{messages: messages}) do
    case List.last(messages) do
      %{role: :assistant, tool_calls: [_ | _]} -> :tools
      _no_tool_calls -> :end
    end
  end

  @doc false
  def run_tools(%{messages: messages}, ctx, tools) do
    %{tool_calls: tool_calls} = List.last(messages)
    %{messages: Enum.map(tool_calls, &execute_call(tools, &1, ctx))}
  end

  defp execute_call(tools, %{id: id, name: name, args: args}, ctx) do
    case find_tool(tools, name) do
      nil ->
        LLM.tool_result(id, name, "error: unknown_tool #{name}")

      tool ->
        case tool_execute(tool, args, ctx) do
          {:ok, result} -> LLM.tool_result(id, name, result)
          {:error, reason} -> LLM.tool_result(id, name, "error: #{inspect(reason)}")
        end
    end
  end

  defp find_tool(tools, name), do: Enum.find(tools, &(tool_spec(&1).name == name))

  defp tool_spec(%MCPTool{} = tool), do: MCPTool.to_tool_spec(tool)
  defp tool_spec(action) when is_atom(action), do: action.to_tool_spec()

  defp tool_execute(%MCPTool{} = tool, args, ctx), do: MCPTool.execute(tool, args, ctx)
  defp tool_execute(action, args, ctx) when is_atom(action), do: Action.execute(action, args, ctx)
end
