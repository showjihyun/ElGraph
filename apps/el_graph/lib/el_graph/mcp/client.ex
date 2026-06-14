defmodule ElGraph.MCP.Client do
  @moduledoc """
  MCP 클라이언트 behaviour (SPEC §4).

  전송 계층(stdio/HTTP/hermes_mcp 등)에 무관하게, ElGraph가 MCP 서버의 툴을
  쓰기 위해 필요한 최소 표면만 정의한다. 실제 전송 어댑터는 별도 패키지로.
  """

  @typedoc "어댑터별 클라이언트 핸들 (커넥션, 설정 등)"
  @type client :: term()

  @typedoc ~S(MCP 툴 정의 — `%{"name" => _, "description" => _, "inputSchema" => _}`)
  @type tool_def :: map()

  @callback list_tools(client()) :: {:ok, [tool_def()]} | {:error, term()}
  @callback call_tool(client(), name :: String.t(), args :: map()) ::
              {:ok, term()} | {:error, term()}
end
