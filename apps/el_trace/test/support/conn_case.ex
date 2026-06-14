defmodule ElTraceWeb.ConnCase do
  @moduledoc """
  LiveView/컨트롤러 테스트용 케이스. 연결(conn)과 LiveViewTest 헬퍼를 주입한다.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ElTraceWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint ElTraceWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
