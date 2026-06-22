defmodule ElTrace.Handoff.Collector do
  @moduledoc """
  `[:el_graph, :agent, :handoff]` 텔레메트리에서 핸드오프 엣지를 모으는 GenServer.

  `start_link/1`에서 서버 ref로 유일한 핸들러 id를 만들어 텔레메트리에 붙이고
  (`async: true` 테스트에서 여러 인스턴스가 공존), terminate에서 뗀다. 핸들러는 엣지를
  서버에 cast하고, `edges/1`/`graph/1`은 GenServer.call이라 직전 cast를 flush한 뒤 읽는다.
  """

  use GenServer

  alias ElTrace.Handoff

  @event [:el_graph, :agent, :handoff]

  # 엣지 버퍼 상한 — 장기 실행에서 무한 증가(메모리 누수)를 막는다. 가장 오래된 엣지부터 버린다.
  @default_max 10_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "모인 엣지를 수신 순서대로 반환한다."
  @spec edges(GenServer.server()) :: [Handoff.edge()]
  def edges(server), do: GenServer.call(server, :edges)

  @doc "모인 엣지로 만든 핸드오프 그래프."
  @spec graph(GenServer.server()) :: Handoff.graph()
  def graph(server), do: Handoff.build(edges(server))

  @doc "모인 엣지를 비운다."
  @spec reset(GenServer.server()) :: :ok
  def reset(server), do: GenServer.call(server, :reset)

  @impl GenServer
  def init(opts) do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        &__MODULE__.handle_event/4,
        self()
      )

    {:ok, %{handler_id: handler_id, edges: [], max: Keyword.get(opts, :max, @default_max)}}
  end

  @doc false
  def handle_event(@event, _measurements, %{from: from, to: to, signal: signal}, server) do
    GenServer.cast(server, {:edge, %{from: from, to: to, signal: signal}})
  end

  # 예상치 못한 메타데이터 형태에도 raise하지 않는다 — raise하면 :telemetry가 이 핸들러를
  # 영구 detach해 이후 핸드오프가 전량 소실된다.
  def handle_event(_event, _measurements, _metadata, _server), do: :ok

  @impl GenServer
  def handle_cast({:edge, edge}, state) do
    # prepend(O(1)) 후 상한까지만 유지 — 읽을 때 reverse로 수신 순서를 복원한다.
    {:noreply, %{state | edges: Enum.take([edge | state.edges], state.max)}}
  end

  @impl GenServer
  def handle_call(:edges, _from, state), do: {:reply, Enum.reverse(state.edges), state}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | edges: []}}

  @impl GenServer
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end
end
