defmodule ElGraph.Skills.SignalReAct do
  @moduledoc """
  시그널 구동 ReAct Skill (SPEC §5, M4 — 도그푸딩 2표본에서 추출).

  DocsAgent(Grounded Q&A)와 SummarizeAgent(Transform)의 공통 골격을 4개 파라미터로
  추출한 것이다. 두 에이전트의 차이는 (라우트, 툴, 시스템 프롬프트, 입력 키)뿐이고
  나머지(react 그래프, 비블로킹 실행, 직렬 큐, crash-only, 결과 리포팅)는 동일하다.

      defmodule MyAgent do
        use ElGraph.Skills.SignalReAct,
          route: "question.*",          # 이 패턴의 시그널만 처리
          input_key: :question,         # signal.data에서 사용자 텍스트를 꺼낼 키
          tools: [MyApp.SearchAction],  # Action 모듈 목록 (런타임 :tools로 MCP 추가 가능)
          system: "너는 ...",
          reply_tag: :answer,           # reply_to에 {reply_tag, %{answer:, usage:}} 전송
          budget: [tokens: 100_000]
      end

      {:ok, _} = MyAgent.start_link(llm: {ElGraph.LLM.OpenAI, api_key: key}, id: "a1",
                                    reply_to: self(), rate_limiter: MyLimiter)

  `:thread`(:per_request | {:fixed, id})와 `:checkpointer`는 `ElGraph.Agent`로 그대로 전달된다.
  결과 reply가 usage를 포함하므로 비용 관측이 가능하다 (도그푸딩 마찰 3 해소).
  """

  alias ElGraph.{LLM, Presets, Signal}
  alias ElGraph.Signal.Bus

  defmacro __using__(skill_opts) do
    quote do
      use ElGraph.Agent

      @skill_opts unquote(skill_opts)

      def start_link(runtime_opts) do
        ElGraph.Skills.SignalReAct.__start_link__(__MODULE__, @skill_opts, runtime_opts)
      end

      @impl ElGraph.Agent
      def handle_signal(signal, context),
        do: ElGraph.Skills.SignalReAct.__handle_signal__(@skill_opts, signal, context)

      @impl ElGraph.Agent
      def handle_result(result, context),
        do: ElGraph.Skills.SignalReAct.__handle_result__(@skill_opts, result, context)

      defoverridable start_link: 1, handle_signal: 2, handle_result: 2
    end
  end

  @doc false
  def __start_link__(module, skill_opts, runtime_opts) do
    llm = Keyword.fetch!(runtime_opts, :llm)
    tools = (skill_opts[:tools] || []) ++ Keyword.get(runtime_opts, :tools, [])

    graph =
      Presets.react(llm, tools,
        system: skill_opts[:system],
        budget: skill_opts[:budget] || [],
        rate_limiter: Keyword.get(runtime_opts, :rate_limiter)
      )

    ElGraph.Agent.Server.start_link(module, Keyword.put(runtime_opts, :graph, graph))
  end

  @doc false
  def __handle_signal__(skill_opts, %Signal{type: type, source: source, data: data}, _context) do
    if Signal.matches?(skill_opts[:route], type) do
      if source do
        :telemetry.execute([:el_graph, :agent, :handoff], %{}, %{
          from: source,
          to: to_string(skill_opts[:reply_tag]),
          signal: type
        })
      end

      text = Map.fetch!(data, skill_opts[:input_key])
      {:run, %{messages: [LLM.user(text)]}}
    else
      :ignore
    end
  end

  @doc false
  def __handle_result__(skill_opts, result, context) do
    payload =
      case result do
        # 결과 reply에 usage 포함 — 비용 관측 가능 (도그푸딩 마찰 3 해소).
        {:ok, %{messages: messages} = state} ->
          %{answer: List.last(messages)[:content], usage: Map.get(state, :usage)}

        other ->
          %{error: other}
      end

    # reply_to: 직접 수신자에게 (테스트/단발 작업)
    if reply_to = context.opts[:reply_to] do
      send(reply_to, {skill_opts[:reply_tag], payload})
    end

    # emit: 결과를 시그널로 버스에 발행 — 멀티 에이전트 핸드오프/파이프라인 (SPEC §6).
    case context.opts[:emit] do
      {bus, type} ->
        Bus.publish(bus, %Signal{
          type: type,
          source: to_string(skill_opts[:reply_tag]),
          data: payload
        })

      nil ->
        :ok
    end

    :ok
  end
end
