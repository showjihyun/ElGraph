defmodule ElGraphWeb.Auth do
  @moduledoc """
  API 키 인증 Plug — `conn.assigns[:api_keys]`의 허용 키 목록으로 요청을 검사한다.

  **Secure by default (fail-closed)**: `api_keys`가 비었거나(`[]`/`nil`) 미설정이면 모든 요청을
  401로 막는다. 비어 있지 않은 키 목록이면 `authorization: "Bearer <key>"` 또는
  `x-api-key: <key>` 헤더의 키가 목록에 있어야 통과한다. 없거나 틀리면 401 JSON
  `{"error":"unauthorized"}`로 응답하고 `halt`한다.

  인증을 **의도적으로** 끄려면(개발/내부망 등) `api_keys: :public`을 명시해야 한다 —
  키 누락 같은 실수로 엔드포인트가 열리지 않도록 개방은 항상 명시적 opt-in이다.
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
      :public -> assign(conn, :caller, :public)
      [_ | _] = keys -> authenticate(conn, keys)
      _ -> unauthorized(conn)
    end
  end

  defp authenticate(conn, keys) do
    presented = presented_key(conn)

    if is_binary(presented) and presented != "" and Enum.any?(keys, &secure_eq?(&1, presented)),
      do: assign(conn, :caller, caller_id(presented)),
      else: unauthorized(conn)
  end

  # 상수 시간 비교 — `==`/`in`의 단축평가가 키를 바이트 단위로 흘리는 타이밍 사이드채널을 막는다.
  defp secure_eq?(key, presented) when is_binary(key),
    do: Plug.Crypto.secure_compare(key, presented)

  defp secure_eq?(_key, _presented), do: false

  # 원시 키 대신 안정적 불투명 식별자를 conn에 실어, Task 등 자원을 호출자별로 스코프한다.
  defp caller_id(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode_to_iodata!(%{"error" => "unauthorized"}))
    |> halt()
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
