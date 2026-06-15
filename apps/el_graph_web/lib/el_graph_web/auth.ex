defmodule ElGraphWeb.Auth do
  @moduledoc """
  API 키 인증 Plug — `conn.assigns[:api_keys]`의 허용 키 목록으로 요청을 검사한다.

  `api_keys`가 `nil`이거나 `[]`이면 인증을 끈다(기존 오픈 동작 유지). 비어 있지 않으면
  `authorization: "Bearer <key>"` 또는 `x-api-key: <key>` 헤더의 키가 목록에 있어야 통과한다.
  없거나 틀리면 401 JSON `{"error":"unauthorized"}`로 응답하고 `halt`한다.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:api_keys] do
      keys when keys in [nil, []] -> conn
      keys when is_list(keys) -> authenticate(conn, keys)
    end
  end

  defp authenticate(conn, keys) do
    if presented_key(conn) in keys do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode_to_iodata!(%{"error" => "unauthorized"}))
      |> halt()
    end
  end

  defp presented_key(conn) do
    bearer =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> key] -> key
        _ -> nil
      end

    bearer || List.first(get_req_header(conn, "x-api-key"))
  end
end
