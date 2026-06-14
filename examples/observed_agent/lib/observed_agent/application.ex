defmodule ObservedAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 이 앱이 소유하는 체크포인터 — 그래프 실행과 el_trace UI가 공유한다.
      {ElGraph.Checkpointer.ETS, name: ObservedAgent.Checkpointer},
      # 부팅 시 그래프를 인터럽트까지 실행하고 ElTrace에 등록한다.
      {Task, &ObservedAgent.seed/0}
    ]

    opts = [strategy: :one_for_one, name: ObservedAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
