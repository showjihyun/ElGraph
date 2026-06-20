defmodule ElGraphWeb.AGUI.Router do
  @moduledoc """
  AG-UI(Agent-User Interaction) HTTP 바인딩 (트렌드 보고서 Tier 1.3).

  `ElGraph.AGUI` 순수 매핑 위의 얇은 Plug 계층. 그래프 실행을 AG-UI 이벤트 SSE 스트림으로
  노출한다. 에이전트 레지스트리는 `conn.assigns.agents`로 주입된다.

    POST /:name/run  → ElGraph.stream → AG-UI 이벤트 (text/event-stream, chunked)
  """

  use Plug.Router

  alias ElGraphWeb.Guardrails
  alias ElGraphWeb.SSE

  # length: 1 MB cap — 멀티 MB 페이로드로 인한 메모리 고갈(OOM)을 막는다.
  # 초과 시 Plug.Parsers가 413(RequestTooLargeError)으로 거부한다.
  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/json"],
    length: 1_000_000
  )

  plug(:match)
  plug(:dispatch)

  post "/:name/run" do
    case Map.fetch(conn.assigns[:agents] || %{}, name) do
      {:ok, spec} -> stream_run(conn, spec)
      :error -> send_json(conn, 404, %{"error" => "unknown agent", "name" => name})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp stream_run(conn, spec) do
    input = atomize_input(conn.body_params)

    case Guardrails.check(conn, input[:question]) do
      {:ok, _} -> run_stream(conn, spec, input)
      {:blocked, reason} -> send_json(conn, 403, blocked_body(reason))
    end
  end

  defp blocked_body(reason), do: %{"error" => "guardrail_blocked", "reason" => inspect(reason)}

  defp run_stream(conn, spec, input) do
    run_id = "run-" <> Integer.to_string(System.unique_integer([:positive]))
    thread_id = Map.get(input, :thread_id, run_id)

    events =
      spec.graph
      |> ElGraph.stream(input, thread_id: thread_id)
      |> ElGraph.AGUI.transform(thread_id, run_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    Enum.reduce_while(events, conn, fn event, conn ->
      case chunk(conn, SSE.encode(event)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  # 최상위 문자열 키를 선언된 상태 채널 atom으로 변환한다 (미선언 키는 버린다).
  defp atomize_input(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_existing_atom(k), v} end)
    |> Map.delete(nil)
  end

  defp to_existing_atom(key) when is_atom(key), do: key

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end
end
