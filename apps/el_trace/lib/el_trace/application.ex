defmodule ElTrace.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:el_trace, :attach_telemetry, true) do
      ElTrace.Telemetry.attach()
    end

    children = base_children() ++ dev_children()

    opts = [strategy: :one_for_one, name: ElTrace.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElTraceWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp base_children do
    [
      {Phoenix.PubSub, name: ElTrace.PubSub},
      {ElTrace.Sessions, name: ElTrace.Sessions},
      {ElTrace.Handoff.Collector, name: ElTrace.Handoff.Collector},
      ElTraceWeb.Endpoint
    ]
  end

  # 개발 환경에서만: 체크포인터 + 시드(승인 대기 thread)를 띄워 페이지에 볼거리를 만든다.
  defp dev_children do
    if Application.get_env(:el_trace, :seed_dev_data, false) do
      [
        {ElGraph.Checkpointer.ETS, name: ElTrace.DevCheckpointer},
        {Task, &ElTrace.DevSeed.run/0}
      ]
    else
      []
    end
  end
end
