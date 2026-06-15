defmodule ElGraphWeb.Router do
  @moduledoc """
  최상위 Plug 라우터 — A2A/AG-UI 서브라우터로 포워딩한다.

  에이전트 레지스트리는 `conn.assigns.agents`에 미리 세팅돼 있어야 한다(`ElGraphWeb.Endpoint`가
  주입). assigns는 forward를 거쳐도 보존된다.
  """

  use Plug.Router

  plug(ElGraphWeb.Auth)
  plug(:match)
  plug(:dispatch)

  forward("/a2a", to: ElGraphWeb.A2A.Router)
  forward("/agui", to: ElGraphWeb.AGUI.Router)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
