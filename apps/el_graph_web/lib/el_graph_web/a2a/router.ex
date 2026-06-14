defmodule ElGraphWeb.A2A.Router do
  @moduledoc """
  A2A(Agent2Agent) HTTP 바인딩 (트렌드 보고서 Tier 1.3).

  `ElGraph.A2A` 순수 매핑 위의 얇은 Plug 계층. 에이전트 레지스트리는 `conn.assigns.agents`
  (`%{name => %{graph:, card:}}`)로 주입된다 — 호스트가 상위 plug에서, 테스트가 직접 assign.

    GET  /:name/agent-card                   → A2A Agent Card (JSON, legacy 경로)
    GET  /:name/.well-known/agent-card.json  → A2A Agent Card (well-known 경로)
    POST /:name/message                      → 메시지로 그래프 invoke → A2A Task 상태 (JSON)
    POST /:name                              → JSON-RPC 2.0 (message/send, tasks/get, message/stream)

  JSON-RPC 디스패치는 순수 헬퍼 `ElGraphWeb.A2A.JSONRPC`가 담당하고, 라우터는 봉투
  (envelope) 직렬화와 SSE 스트리밍만 한다. Task 저장소는 `conn.assigns.task_store`로
  주입된다(에이전트 레지스트리와 동일한 방식).
  """

  use Plug.Router

  alias ElGraphWeb.A2A.JSONRPC
  alias ElGraphWeb.SSE

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:match)
  plug(:dispatch)

  get "/:name/agent-card" do
    send_agent_card(conn, name)
  end

  get "/:name/.well-known/agent-card.json" do
    send_agent_card(conn, name)
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

  post "/:name" do
    case agent(conn, name) do
      {:ok, spec} -> dispatch_rpc(conn, spec)
      :error -> send_json(conn, 404, %{"error" => "unknown agent", "name" => name})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp send_agent_card(conn, name) do
    case agent(conn, name) do
      {:ok, spec} -> send_json(conn, 200, ElGraph.A2A.agent_card(spec.card))
      :error -> send_json(conn, 404, %{"error" => "unknown agent", "name" => name})
    end
  end

  defp dispatch_rpc(conn, spec) do
    body = conn.body_params
    id = Map.get(body, "id")
    deps = %{graph: spec.graph, task_store: conn.assigns[:task_store]}

    case JSONRPC.handle(Map.get(body, "method"), Map.get(body, "params", %{}), deps) do
      {:result, result} ->
        send_json(conn, 200, envelope(id, result: result))

      {:error, code, message} ->
        send_json(conn, 200, envelope(id, error: %{"code" => code, "message" => message}))

      {:stream, frames} ->
        stream_rpc(conn, id, frames)
    end
  end

  defp envelope(id, result: result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp envelope(id, error: error), do: %{"jsonrpc" => "2.0", "id" => id, "error" => error}

  defp stream_rpc(conn, id, frames) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    Enum.reduce_while(frames, conn, fn frame, conn ->
      case chunk(conn, SSE.encode(%{frame | "id" => id})) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
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
