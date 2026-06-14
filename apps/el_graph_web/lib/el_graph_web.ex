defmodule ElGraphWeb do
  @moduledoc """
  ElGraph용 HTTP 바인딩 — A2A(에이전트↔에이전트)와 AG-UI(에이전트↔프론트엔드) 프로토콜
  서버 (트렌드 보고서 Tier 1.3).

  순수 매핑(`ElGraph.A2A`/`ElGraph.AGUI`) 위의 얇은 Plug 계층이다. ElGraph 원칙대로 전역
  서버를 자동 시작하지 않는다 — 호스트 앱이 `server_spec/1`을 자신의 슈퍼비전 트리에 마운트한다.

      children = [
        ElGraphWeb.server_spec(agents: %{"docs" => %{graph: graph, card: [...]}}, port: 4001)
      ]

  엔드포인트:

      GET  /a2a/:name/agent-card    A2A Agent Card
      POST /a2a/:name/message       A2A Task 실행
      POST /agui/:name/run          AG-UI 이벤트 SSE 스트림
  """

  @typedoc "에이전트 스펙: 컴파일된 그래프 + Agent Card 옵션."
  @type agent_spec :: %{required(:graph) => ElGraph.Graph.t(), required(:card) => keyword()}

  @doc """
  호스트 슈퍼비전 트리에 마운트할 Bandit child_spec를 만든다.

  옵션 `:task_store`(A2A Task 저장소 ref — `ElGraphWeb.TaskStore` 등)를 주면 A2A
  JSON-RPC `message/send`/`tasks/get`가 그 저장소를 쓴다. 저장소 프로세스 자체는 호스트가
  별도로 슈퍼비전한다(`ElGraphWeb.TaskStore`).
  """
  @spec server_spec(keyword()) :: Supervisor.child_spec() | {module(), keyword()}
  def server_spec(opts) do
    agents = Keyword.fetch!(opts, :agents)
    port = Keyword.get(opts, :port, 4001)
    task_store = Keyword.get(opts, :task_store)
    {Bandit, plug: {ElGraphWeb.Endpoint, agents: agents, task_store: task_store}, port: port}
  end
end
