defmodule ElGraphWeb.A2A.Router do
  @moduledoc """
  A2A(Agent2Agent) HTTP 바인딩 (트렌드 보고서 Tier 1.3).

  `ElGraph.A2A` 순수 매핑 위의 얇은 Plug 계층. 에이전트 레지스트리는 `conn.assigns.agents`
  (`%{name => %{graph:, card:}}`)로 주입된다 — 호스트가 상위 plug에서, 테스트가 직접 assign.

    GET  /:name/agent-card  → A2A Agent Card (JSON)
    POST /:name/message     → 메시지로 그래프 invoke → A2A Task 상태 (JSON)
  """

  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:match)
  plug(:dispatch)

  get "/:name/agent-card" do
    case agent(conn, name) do
      {:ok, spec} -> send_json(conn, 200, ElGraph.A2A.agent_card(spec.card))
      :error -> send_json(conn, 404, %{"error" => "unknown agent", "name" => name})
    end
  end

  post "/:name/message" do
    case agent(conn, name) do
      {:ok, spec} ->
        input = ElGraph.A2A.message_to_input(conn.body_params)
        task = ElGraph.A2A.to_task_state(ElGraph.invoke(spec.graph, input))
        send_json(conn, 200, task)

      :error ->
        send_json(conn, 404, %{"error" => "unknown agent", "name" => name})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp agent(conn, name) do
    case Map.fetch(conn.assigns[:agents] || %{}, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> :error
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end
end
