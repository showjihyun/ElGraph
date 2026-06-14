defmodule ElGraphWeb.Application do
  @moduledoc false
  # ElGraph 원칙: 라이브러리는 전역 서버를 자동 시작하지 않는다. 빈 슈퍼바이저만 띄우고,
  # 호스트 앱이 Bandit child_spec(`ElGraphWeb.server_spec/1`)를 자신의 트리에 마운트한다.

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: ElGraphWeb.Supervisor)
  end
end
