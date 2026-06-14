defmodule ElGraph.Agent do
  @moduledoc """
  장수명 에이전트 = 그래프 + 영속 상태 + 메일박스를 가진 GenServer (SPEC §5).

      defmodule MyApp.ResearchAgent do
        use ElGraph.Agent

        @impl true
        def handle_signal(%ElGraph.Signal{data: data}, _context), do: {:run, data}

        @impl true
        def handle_result({:ok, state}, context), do: MyApp.notify(context.id, state)
      end

      {:ok, pid} = MyApp.ResearchAgent.start_link(graph: graph, id: "r1", checkpointer: cp)
      ElGraph.Agent.send_signal(pid, %ElGraph.Signal{type: "task.assigned", data: %{...}})

  실행은 GenServer 콜백 밖(별도 프로세스, nolink+monitor)에서 돌므로 에이전트는
  실행 중에도 시그널을 받는다. 실행 중 도착한 `{:run, _}`은 큐에 들어가 직렬 처리된다.
  체크포인터가 있으면 재시작 시 미완료 thread를 자동 재개한다 (crash-only, SPEC §5).
  """

  alias ElGraph.Signal

  @typedoc "콜백에 전달되는 컨텍스트: `%{id:, opts:}`"
  @type context :: %{id: term(), opts: keyword()}

  @doc "시그널을 받았을 때 — 그래프를 돌릴지(input과 함께) 무시할지 결정한다."
  @callback handle_signal(Signal.t(), context()) :: {:run, map()} | :ignore

  @doc "실행 결과를 받았을 때. 기본 구현은 no-op."
  @callback handle_result(ElGraph.Executor.result(), context()) :: :ok
  @optional_callbacks handle_result: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour ElGraph.Agent

      def start_link(opts), do: ElGraph.Agent.Server.start_link(__MODULE__, opts)

      def child_spec(opts) do
        %{
          id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          restart: :permanent
        }
      end

      @impl ElGraph.Agent
      def handle_result(_result, _context), do: :ok

      defoverridable handle_result: 2, child_spec: 1, start_link: 1
    end
  end

  @doc "에이전트에 시그널을 보낸다 (비동기)."
  @spec send_signal(GenServer.server(), Signal.t()) :: :ok
  def send_signal(server, %Signal{} = signal), do: GenServer.cast(server, {:signal, signal})

  @doc "에이전트 상태 요약: `%{id:, running:, queued:}` — 실행 중에도 응답한다."
  @spec status(GenServer.server()) :: %{id: term(), running: boolean(), queued: non_neg_integer()}
  def status(server), do: GenServer.call(server, :status)

  @doc "Registry 기반 이름 — 동적 atom을 만들지 않는다 (SPEC §5)."
  @spec via(atom(), term()) :: {:via, Registry, {atom(), term()}}
  def via(registry, id), do: {:via, Registry, {registry, id}}
end
