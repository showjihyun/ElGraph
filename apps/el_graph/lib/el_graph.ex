defmodule ElGraph do
  @moduledoc """
  Graph-first 에이전트 오케스트레이션의 코어: 상태 채널 + 노드 + 엣지로 그래프를
  선언하고, superstep 루프로 실행한다. 설계 전문은 `docs/SPEC.md`.

  ## 예제

      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
        |> ElGraph.add_node(:agent, &MyApp.Agent.call/2)
        |> ElGraph.add_node(:tools, &MyApp.Tools.call/2)
        |> ElGraph.add_edge(:tools, :agent)
        |> ElGraph.add_conditional_edge(:agent, &MyApp.Router.route/1)
        |> ElGraph.compile(entry: :agent)

      {:ok, state} = ElGraph.invoke(graph, %{messages: [user_msg]})

  노드는 `(state, ctx)`를 받아 상태 부분 업데이트 맵을 반환한다.
  durable 그래프(체크포인트 재개)의 노드는 MFA 또는 원격 캡처(`&Mod.fun/2`)를 권장한다.
  """

  alias ElGraph.{CompileError, Executor, Graph}

  @doc "빈 그래프를 만든다."
  @spec new() :: Graph.t()
  def new, do: %Graph{}

  @doc """
  상태 키(채널)를 선언한다.

  ## 옵션

    * `:default` — 초기값 (기본 `nil`)
    * `:reducer` — 쓰기 병합 함수 `(현재값, 새값) -> 병합값`.
      MFA 또는 원격 캡처만 허용(SPEC §3.1). 미지정 시 overwrite.
  """
  @spec state(Graph.t(), atom(), keyword()) :: Graph.t()
  def state(%Graph{} = graph, key, opts \\ []) when is_atom(key) do
    definition = %{default: Keyword.get(opts, :default), reducer: Keyword.get(opts, :reducer)}
    %{graph | state_def: Map.put(graph.state_def, key, definition)}
  end

  @doc """
  노드를 추가한다. `run`은 MFA `{m, f, extra_args}` 또는 2-인자 함수.

  ## 옵션

    * `:input` — 노드에 전달할 상태 키 목록 (input projection, SPEC §3.4)
    * `:timeout` — 노드 실행 시간 상한(ms, 기본 `:infinity`). 초과 시
      `{:error, {:node_timeout, node, ms}}` — 병렬 형제의 완료된 쓰기는 보존된다
  """
  @spec add_node(Graph.t(), atom(), Graph.node_run(), keyword()) :: Graph.t()
  def add_node(%Graph{} = graph, name, run, opts \\ []) when is_atom(name) do
    %{graph | nodes: Map.put(graph.nodes, name, %{run: run, opts: opts})}
  end

  @doc "고정 엣지를 추가한다. `to`는 노드 이름 또는 `:end`."
  @spec add_edge(Graph.t(), atom(), atom()) :: Graph.t()
  def add_edge(%Graph{} = graph, from, to) when is_atom(from) and is_atom(to) do
    %{graph | edges: Map.update(graph.edges, from, [to], &(&1 ++ [to]))}
  end

  @doc """
  조건부 엣지를 추가한다. `router`는 `(state) -> 노드이름 | :end`.

  라우터는 순수해야 한다(SPEC §3.3) — 재개·리플레이 시 재평가된다.
  """
  @spec add_conditional_edge(Graph.t(), atom(), Graph.router()) :: Graph.t()
  def add_conditional_edge(%Graph{} = graph, from, router) when is_atom(from) do
    %{graph | routers: Map.put(graph.routers, from, router)}
  end

  @doc """
  그래프를 검증하고 실행 가능한 형태로 확정한다. 유효하지 않으면 `ElGraph.CompileError`.

  검증 항목(SPEC §3.3): entry 존재, 엣지/라우터 대상 존재, reducer 형태(MFA/원격 캡처),
  `:input` 키 선언 여부, 도달 불가 노드(정적 엣지만 있는 그래프에 한해).
  """
  @spec compile(Graph.t(), keyword()) :: Graph.t()
  def compile(%Graph{} = graph, opts \\ []) do
    entry =
      Keyword.get(opts, :entry) ||
        raise CompileError, "entry node is required: compile(graph, entry: :node_name)"

    ensure_node!(graph, entry, "entry")
    validate_edges!(graph)
    validate_routers!(graph)
    validate_reducers!(graph)
    validate_nodes!(graph)
    validate_reachability!(graph, entry)

    %{graph | entry: entry}
  end

  @doc """
  그래프를 실행하고 최종 상태를 반환한다.

  ## 옵션

    * `:max_steps` — superstep 상한 (기본 25). 초과 시 `{:error, {:max_steps_exceeded, _}}`
    * `:max_concurrency` — 한 superstep의 병렬 노드 동시 실행 상한 (기본 코어 수).
      LLM/HTTP 같은 I/O 바운드 fan-out은 더 높게 주는 게 유리하다 (SPEC §3.4)
    * `:thread_id` — 실행 식별자 (기본 자동 생성). 체크포인트/재개의 키
    * `:event_sink` — `ElGraph.Ctx.emit/2` 이벤트를 받을 pid
    * `:checkpointer` — `{module, config}`. 지정 시 초기 상태와 매 superstep 후 체크포인트 저장
    * `:interrupt_before` — 노드 목록. 해당 노드 진입 전에 `{:interrupted, info}` 반환 (`:checkpointer` 필수)
    * `:durability` — 체크포인트 영속 시점 (SPEC §3.5). `:sync`(기본, 매 step 동기) /
      `:async`(순서 보장 writer에 비동기, 반환 전 flush) / `:exit`(완료·인터럽트만 영속, 가장 빠름)
  """
  @spec invoke(Graph.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:interrupted, map()}
  def invoke(%Graph{entry: entry} = graph, input, opts \\ []) do
    if entry == nil do
      raise ArgumentError, "graph is not compiled — call ElGraph.compile/2 first"
    end

    if Keyword.has_key?(opts, :interrupt_before) and not Keyword.has_key?(opts, :checkpointer) do
      raise ArgumentError,
            ":interrupt_before requires a :checkpointer — an interrupt must be resumable"
    end

    Executor.run(graph, input, opts)
  end

  @doc """
  체크포인트에서 실행을 재개한다 (SPEC §3.5).

  마지막 체크포인트의 상태와 활성 노드에서 이어가며, 부분 실패한 superstep의
  pending writes가 있으면 완료된 노드를 재실행하지 않는다.

  필수 옵션: `:checkpointer` (`{module, config}`), `:thread_id`.
  동적 인터럽트 재개 시 `:resume` 옵션의 값이 `ElGraph.Ctx.interrupt/2`의
  반환값으로 주입된다 (노드는 처음부터 재실행, 호출 순서로 매칭 — SPEC §3.6).
  체크포인트가 없으면 `{:error, :no_checkpoint}`,
  인터럽트되지 않았는데 `:resume`을 주면 `{:error, :nothing_to_resume}`.
  """
  @spec resume(Graph.t(), keyword()) :: {:ok, map()} | {:error, term()} | {:interrupted, map()}
  def resume(%Graph{entry: entry} = graph, opts) do
    if entry == nil do
      raise ArgumentError, "graph is not compiled — call ElGraph.compile/2 first"
    end

    Keyword.fetch!(opts, :checkpointer)
    Keyword.fetch!(opts, :thread_id)
    Executor.resume(graph, opts)
  end

  @doc """
  그래프를 실행하며 이벤트를 lazy 스트림으로 반환한다 (SPEC §3.7).

  스트림 원소는 `%{thread_id:, step:, node:, event:}` 맵이다:
  생명주기 이벤트(`:node_start`/`:node_end`), `ElGraph.Ctx.emit/2`의 사용자 이벤트,
  마지막으로 `{:done, result}`. 실행 프로세스는 호출자에 link되며,
  스트림을 조기 중단하면 정리(kill)된다.
  """
  @spec stream(Graph.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(%Graph{entry: entry} = graph, input, opts \\ []) do
    if entry == nil do
      raise ArgumentError, "graph is not compiled — call ElGraph.compile/2 first"
    end

    ElGraph.Runner.stream(graph, input, opts)
  end

  ## compile 검증

  defp ensure_node!(%Graph{nodes: nodes}, name, role) do
    unless Map.has_key?(nodes, name) do
      raise CompileError, "#{role} references unknown node #{inspect(name)}"
    end
  end

  defp validate_edges!(%Graph{edges: edges} = graph) do
    for {from, targets} <- edges do
      ensure_node!(graph, from, "edge source")

      for to <- targets, to != :end do
        ensure_node!(graph, to, "edge from #{inspect(from)}")
      end
    end

    :ok
  end

  defp validate_routers!(%Graph{routers: routers} = graph) do
    for {from, router} <- routers do
      ensure_node!(graph, from, "conditional edge source")

      case router do
        {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
          :ok

        fun when is_function(fun, 1) ->
          :ok

        other ->
          raise CompileError,
                "router for #{inspect(from)} must be an MFA or 1-arity function, got: #{inspect(other)}"
      end
    end

    :ok
  end

  # SPEC §3.1: 로컬 익명 함수 reducer는 코드 리로드/재배포 후 재개 시 badfun으로 깨지므로 거부.
  defp validate_reducers!(%Graph{state_def: state_def}) do
    for {key, %{reducer: reducer}} <- state_def, reducer != nil do
      case reducer do
        {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
          :ok

        fun when is_function(fun, 2) ->
          case Function.info(fun, :type) do
            {:type, :external} ->
              :ok

            _ ->
              raise CompileError,
                    "reducer for #{inspect(key)} must be an MFA or remote capture (&Mod.fun/2) — " <>
                      "local anonymous functions break checkpoint resume across code reloads"
          end

        other ->
          raise CompileError,
                "reducer for #{inspect(key)} must be an MFA or 2-arity remote capture, got: #{inspect(other)}"
      end
    end

    :ok
  end

  defp validate_nodes!(%Graph{nodes: nodes, state_def: state_def}) do
    for {name, %{run: run, opts: opts}} <- nodes do
      case run do
        # 서브그래프 (SPEC §3.10) — 컴파일된 그래프만 노드가 될 수 있다.
        %Graph{entry: nil} ->
          raise CompileError,
                "subgraph for node #{inspect(name)} is not compiled — call ElGraph.compile/2 first"

        %Graph{} ->
          :ok

        {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
          :ok

        fun when is_function(fun, 2) ->
          # SPEC §3.2: durable 그래프에서 로컬 익명 함수 노드는 권장하지 않는다(허용은 함).
          case Function.info(fun, :type) do
            {:type, :external} ->
              :ok

            _ ->
              IO.warn(
                "node #{inspect(name)} uses a local anonymous function — prefer MFA or &Mod.fun/2 for durable graphs"
              )
          end

        other ->
          raise CompileError,
                "node #{inspect(name)} must be an MFA or 2-arity function, got: #{inspect(other)}"
      end

      for key <- Keyword.get(opts, :input, []) do
        unless Map.has_key?(state_def, key) do
          raise CompileError,
                "node #{inspect(name)} :input references undeclared state key #{inspect(key)}"
        end
      end

      case Keyword.get(opts, :timeout, :infinity) do
        :infinity ->
          :ok

        ms when is_integer(ms) and ms > 0 ->
          :ok

        other ->
          raise CompileError,
                "node #{inspect(name)} :timeout must be a positive integer (ms) or :infinity, got: #{inspect(other)}"
      end

      validate_retry!(name, Keyword.get(opts, :retry, []))
    end

    :ok
  end

  defp validate_retry!(_name, []), do: :ok

  defp validate_retry!(name, retry) when is_list(retry) do
    max = Keyword.get(retry, :max, 0)
    backoff = Keyword.get(retry, :backoff, :none)
    base = Keyword.get(retry, :base, 100)
    retry_on = Keyword.get(retry, :retry_on)

    valid? =
      is_integer(max) and max >= 0 and backoff in [:none, :exponential] and
        is_integer(base) and base > 0 and
        (retry_on == nil or (is_list(retry_on) and Enum.all?(retry_on, &is_atom/1)))

    unless valid? do
      raise CompileError,
            "node #{inspect(name)} :retry must be [max: non_neg_integer, backoff: :none | :exponential, " <>
              "base: pos_integer, retry_on: nil | [module]], got: #{inspect(retry)}"
    end

    :ok
  end

  defp validate_retry!(name, other) do
    raise CompileError,
          "node #{inspect(name)} :retry must be a keyword list, got: #{inspect(other)}"
  end

  # 라우터가 있으면 동적 대상 때문에 정적 도달성 판단이 불가능하므로 검사를 건너뛴다 (SPEC §3.3).
  defp validate_reachability!(%Graph{routers: routers} = graph, entry)
       when map_size(routers) == 0 do
    reachable = reachable_from(graph, entry)

    unreachable =
      graph.nodes |> Map.keys() |> Enum.reject(&Map.has_key?(reachable, &1)) |> Enum.sort()

    unless unreachable == [] do
      # :send/:command 의 동적 대상은 정적으로 알 수 없으므로 에러가 아닌 경고다.
      IO.warn(
        "unreachable nodes (no static path from entry): #{inspect(unreachable)} — " <>
          "fine if they are :send/:command targets"
      )
    end

    :ok
  end

  defp validate_reachability!(%Graph{}, _entry), do: :ok

  # 방문 집합은 plain map(키=노드)로 둔다 — MapSet opaque 타입은 Dialyzer 경계 추적이 끊겨
  # false-positive opaque 경고를 내므로 동등한 map-as-set을 쓴다.
  @spec reachable_from(Graph.t(), atom()) :: %{atom() => true}
  defp reachable_from(%Graph{edges: edges}, entry), do: do_reach(edges, [entry], %{})

  @spec do_reach(%{atom() => [atom()]}, [atom()], %{atom() => true}) :: %{atom() => true}
  defp do_reach(_edges, [], visited), do: visited

  defp do_reach(edges, [node | rest], visited) do
    if Map.has_key?(visited, node) or node == :end do
      do_reach(edges, rest, visited)
    else
      do_reach(edges, Map.get(edges, node, []) ++ rest, Map.put(visited, node, true))
    end
  end
end
