defmodule ElGraph.Orchestration do
  @moduledoc """
  멀티 에이전트 오케스트레이션 패턴 템플릿 (SPEC §6, R5; 트렌드 보고서 Tier 2.5).

  빌딩 블록은 기존 프리미티브뿐이다 — 조건부 엣지 + 노드(워커) + `:messages` 채널. 신규
  추상화 없이, 자주 쓰는 멀티 에이전트 형태를 미리 조립한 컴파일된 그래프로 제공한다.

  ## supervisor (오케스트레이터-워커)

  오케스트레이터 노드가 LLM으로 다음 워커를 고르고(또는 종료), 조건부 엣지가 해당 워커로
  라우팅한다. 워커는 결과를 `:messages`에 append하고 오케스트레이터로 복귀한다. `max_steps`로
  라운드 폭주를 막는다.

      workers = [
        %{name: :researcher, description: "gathers facts", run: &MyApp.research/2},
        %{name: :writer, description: "writes the answer", run: &MyApp.write/2}
      ]
      graph = ElGraph.Orchestration.supervisor(llm, workers, system: "...")
      ElGraph.invoke(graph, %{messages: [ElGraph.LLM.user("Write a report")]})

  ## magentic (task-ledger)

  `magentic/3` is `supervisor/3` plus a **task ledger** and a **stall guard**
  (magentic-one pattern). The ledger (`:ledger` channel) records every worker the
  orchestrator chooses; when the same worker is picked more than `:max_stalls`
  times in a row the run is forced to terminate, defusing the classic
  "agent loops forever" failure.

  ## Cross-agent handoff

  In both templates worker results flow back to the orchestrator purely via the
  shared `:messages` channel — a worker appends its output and the orchestrator
  reads the full transcript on its next turn. Direct, out-of-band handoff between
  agents is also expressible without new orchestration code: have a worker emit on
  the signal bus (`ElGraph.Skills.SignalReAct` `:emit`) and have the target worker
  subscribe — the bus delivers the payload independently of the `:messages`
  transcript. The orchestration templates here deliberately stick to `:messages`;
  the signal bus is the escape hatch when you need agent-to-agent side-channels.
  """

  alias ElGraph.{LLM, LLMError, Reducers}

  @done :__done__

  @typedoc "워커 스펙: 노드 이름(atom) + 설명 + 실행 함수(`(state, ctx) -> 상태 업데이트`)."
  @type worker :: %{
          required(:name) => atom(),
          required(:description) => String.t(),
          required(:run) => (map(), ElGraph.Ctx.t() -> map())
        }

  @doc """
  오케스트레이터-워커 그래프를 빌드한다.

  `opts`: `:system`(오케스트레이터 시스템 프롬프트 보강), `:max_steps`(기본 25).
  """
  @spec supervisor({module(), term()}, [worker()], keyword()) :: ElGraph.Graph.t()
  def supervisor(llm, workers, opts \\ []) when is_list(workers) and workers != [] do
    cfg = %{llm: llm, workers: workers, system: Keyword.get(opts, :system)}

    graph =
      ElGraph.new()
      |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
      |> ElGraph.state(:usage,
        default: %{input_tokens: 0, output_tokens: 0},
        reducer: {LLM, :add_usage, []}
      )
      |> ElGraph.state(:next, default: nil)
      |> ElGraph.add_node(:orchestrator, {__MODULE__, :orchestrate, [cfg]})
      |> ElGraph.add_conditional_edge(:orchestrator, {__MODULE__, :route, []})

    graph =
      Enum.reduce(workers, graph, fn worker, g ->
        g
        |> ElGraph.add_node(worker.name, {__MODULE__, :run_worker, [worker]})
        |> ElGraph.add_edge(worker.name, :orchestrator)
      end)

    ElGraph.compile(graph, entry: :orchestrator, max_steps: Keyword.get(opts, :max_steps, 25))
  end

  @doc """
  magentic(task-ledger) 그래프를 빌드한다 — `supervisor/3` + 작업 원장 + 정체(stall) 가드.

  오케스트레이터가 매 턴 다음 워커를 고르고, 선택을 원장(`:ledger.chosen`)에 기록한다.
  동일 워커를 `:max_stalls`회를 **초과**해 연속 선택하면(기본 2) 강제 종료한다 —
  "에이전트 무한 루프" 실패를 막는 결정적·테스트 가능한 가드다.

  `opts`: `:system`(시스템 프롬프트 보강), `:max_stalls`(기본 2), `:max_steps`(기본 25).
  """
  @spec magentic({module(), term()}, [worker()], keyword()) :: ElGraph.Graph.t()
  def magentic(llm, workers, opts \\ []) when is_list(workers) and workers != [] do
    cfg = %{
      llm: llm,
      workers: workers,
      system: Keyword.get(opts, :system),
      max_stalls: Keyword.get(opts, :max_stalls, 2)
    }

    graph =
      ElGraph.new()
      |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
      |> ElGraph.state(:usage,
        default: %{input_tokens: 0, output_tokens: 0},
        reducer: {LLM, :add_usage, []}
      )
      |> ElGraph.state(:next, default: nil)
      |> ElGraph.state(:ledger, default: %{chosen: [], stalls: 0})
      |> ElGraph.add_node(:orchestrator, {__MODULE__, :magentic_orchestrate, [cfg]})
      |> ElGraph.add_conditional_edge(:orchestrator, {__MODULE__, :route, []})

    graph =
      Enum.reduce(workers, graph, fn worker, g ->
        g
        |> ElGraph.add_node(worker.name, {__MODULE__, :run_worker, [worker]})
        |> ElGraph.add_edge(worker.name, :orchestrator)
      end)

    ElGraph.compile(graph, entry: :orchestrator, max_steps: Keyword.get(opts, :max_steps, 25))
  end

  @doc """
  group-chat 그래프를 빌드한다 — 스피커 선택 정책으로 매 턴 발화자를 고른다.

  `opts`: `:select`(`(state -> agent_name | :end)` 순수 정책 — 미지정 시 `:rounds`회
  라운드로빈), `:rounds`(기본 6), `:max_steps`.
  """
  @spec group_chat([worker()], keyword()) :: ElGraph.Graph.t()
  def group_chat(agents, opts \\ []) when is_list(agents) and agents != [] do
    rounds = Keyword.get(opts, :rounds, 6)
    select = Keyword.get(opts, :select, default_round_robin(agents, rounds))
    cfg = %{select: select}

    graph =
      ElGraph.new()
      |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
      |> ElGraph.state(:turn, default: 0, reducer: {__MODULE__, :incr, []})
      |> ElGraph.state(:next, default: nil)
      |> ElGraph.add_node(:moderator, {__MODULE__, :moderate, [cfg]})
      |> ElGraph.add_conditional_edge(:moderator, {__MODULE__, :route, []})

    graph =
      Enum.reduce(agents, graph, fn agent, g ->
        g
        |> ElGraph.add_node(agent.name, {__MODULE__, :run_worker, [agent]})
        |> ElGraph.add_edge(agent.name, :moderator)
      end)

    ElGraph.compile(graph,
      entry: :moderator,
      max_steps: Keyword.get(opts, :max_steps, rounds * 2 + 2)
    )
  end

  @doc false
  def moderate(state, _ctx, cfg) do
    case cfg.select.(state) do
      :end -> %{next: @done}
      name -> %{next: name, turn: 1}
    end
  end

  @doc false
  def incr(current, delta), do: current + delta

  defp default_round_robin(agents, rounds) do
    names = Enum.map(agents, & &1.name)
    n = length(names)

    fn %{turn: turn} ->
      if turn >= rounds, do: :end, else: Enum.at(names, rem(turn, n))
    end
  end

  @doc false
  def orchestrate(%{messages: messages}, _ctx, cfg) do
    {mod, config} = cfg.llm
    system = orchestrator_system(cfg.workers, cfg.system)

    case mod.chat(config, messages, system: system) do
      {:ok, %{message: message} = response} ->
        %{
          messages: [message],
          next: parse_choice(message[:content], cfg.workers),
          usage: Map.get(response, :usage)
        }

      {:error, reason} ->
        raise LLMError, reason: reason
    end
  end

  @doc false
  def magentic_orchestrate(%{messages: messages, ledger: ledger}, _ctx, cfg) do
    {mod, config} = cfg.llm
    system = orchestrator_system(cfg.workers, cfg.system)

    case mod.chat(config, messages, system: system) do
      {:ok, %{message: message} = response} ->
        choice = parse_choice(message[:content], cfg.workers)
        {next, new_ledger} = apply_ledger(ledger, choice, cfg.max_stalls)

        %{
          messages: [message],
          next: next,
          ledger: new_ledger,
          usage: Map.get(response, :usage)
        }

      {:error, reason} ->
        raise LLMError, reason: reason
    end
  end

  # 선택을 원장에 기록하고, 동일 워커 연속 선택이 max_stalls를 초과하면 강제 종료한다.
  defp apply_ledger(ledger, @done, _max_stalls) do
    {@done, ledger}
  end

  defp apply_ledger(%{chosen: chosen, stalls: stalls}, choice, max_stalls) do
    # `stalls` counts consecutive repeats of the same worker (1 = chosen twice in a
    # row, 2 = three times, ...). When it reaches `max_stalls` the run is forced to
    # terminate before the worker is dispatched again.
    stalls = if List.last(chosen) == choice, do: stalls + 1, else: 0
    new_ledger = %{chosen: chosen ++ [choice], stalls: stalls}

    if stalls >= max_stalls do
      {@done, new_ledger}
    else
      {choice, new_ledger}
    end
  end

  @doc false
  def route(%{next: @done}), do: :end
  def route(%{next: nil}), do: :end
  def route(%{next: worker}), do: worker

  @doc false
  def run_worker(state, ctx, worker), do: worker.run.(state, ctx)

  ## 내부

  defp orchestrator_system(workers, extra) do
    roster =
      workers
      |> Enum.map_join("\n", fn w -> "- #{w.name}: #{w.description}" end)

    base =
      """
      You are an orchestrator coordinating specialist workers. Available workers:
      #{roster}

      Reply with EXACTLY one worker name to delegate the next step to, or DONE if the
      task is complete. Reply with the name only — no other text.
      """

    if extra, do: extra <> "\n\n" <> base, else: base
  end

  # assistant 응답에서 워커 선택을 파싱한다. 매칭 실패는 안전하게 종료(DONE)로 본다.
  defp parse_choice(nil, _workers), do: @done

  defp parse_choice(content, workers) when is_binary(content) do
    normalized = content |> String.downcase() |> String.trim()

    cond do
      String.contains?(normalized, "done") -> @done
      worker = match_worker(normalized, workers) -> worker.name
      true -> @done
    end
  end

  defp match_worker(normalized, workers) do
    Enum.find(workers, fn w -> String.contains?(normalized, to_string(w.name)) end)
  end
end
