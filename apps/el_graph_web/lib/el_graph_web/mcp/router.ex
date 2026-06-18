defmodule ElGraphWeb.MCP.Router do
  @moduledoc """
  MCP 서버 HTTP 바인딩 — ElGraph Action을 외부 MCP 클라이언트(Claude 등)에 노출한다.

  `ElGraph.MCP.Server` 순수 디스패치 위의 얇은 Plug 계층(MCP Streamable HTTP).
  단일 엔드포인트 `POST /`에서 JSON-RPC 2.0을 받아 처리하고 JSON으로 응답한다.

  주입(상위 plug 또는 테스트의 `assign`):

    * `:mcp_tools`       — 노출할 `ElGraph.Action` 모듈 목록 (필수)
    * `:mcp_server_info` — `%{"name" => ..., "version" => ...}` (선택)
    * `:mcp_context`     — Action `run/2` 컨텍스트 (선택)

  알림(`notifications/*`, JSON-RPC notification)은 본문 없이 `202`로 응답한다.
  JSON-RPC 에러도 HTTP 200 + error 봉투로 돌려준다(전송은 성공).
  """

  use Plug.Router

  alias ElGraph.MCP.Server
  alias ElGraphWeb.Guardrails

  @default_server_info %{"name" => "el_graph", "version" => "0.2.0"}

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:match)
  plug(:dispatch)

  post "/" do
    body = conn.body_params
    method = Map.get(body, "method")
    params = Map.get(body, "params", %{})

    deps = %{
      tools: conn.assigns[:mcp_tools] || [],
      server_info: conn.assigns[:mcp_server_info] || @default_server_info,
      context: conn.assigns[:mcp_context] || %{}
    }

    case guard(conn, method, params) do
      {:blocked, reason} ->
        error = %{
          "code" => -32602,
          "message" => "Invalid params: guardrail blocked (#{inspect(reason)})"
        }

        send_json(conn, envelope(Map.get(body, "id"), error: error))

      :ok ->
        dispatch_rpc(conn, body, method, params, deps)
    end
  end

  # tools/call의 인자를 입력 가드레일로 검사한다(A2A와 동일 — PII/콘텐츠 필터).
  defp guard(conn, "tools/call", %{"arguments" => args}) do
    case Guardrails.check(conn, Jason.encode!(args)) do
      {:ok, _} -> :ok
      blocked -> blocked
    end
  end

  defp guard(_conn, _method, _params), do: :ok

  defp dispatch_rpc(conn, body, method, params, deps) do
    case Server.handle(method, params, deps) do
      :notification ->
        send_resp(conn, 202, "")

      {:result, result} ->
        send_json(conn, envelope(Map.get(body, "id"), result: result))

      {:error, code, message} ->
        send_json(
          conn,
          envelope(Map.get(body, "id"), error: %{"code" => code, "message" => message})
        )
    end
  end

  match _ do
    send_json(conn, %{"error" => "not found"}, 404)
  end

  defp envelope(id, result: result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  defp envelope(id, error: error), do: %{"jsonrpc" => "2.0", "id" => id, "error" => error}

  defp send_json(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end
end
