defmodule ElGraph.MCP.Server do
  @moduledoc """
  ElGraph Action을 **MCP 서버**로 노출하는 순수 JSON-RPC 2.0 디스패치 (SPEC §4).

  `ElGraph.MCP`가 외부 MCP 서버의 툴을 *소비*하는 클라이언트라면, 이건 그 반대 —
  외부 에이전트(Claude 등 MCP 클라이언트)가 ElGraph Action을 호출하게 한다.
  전송(transport) 무관한 순수 함수이므로 stdio/HTTP 어느 바인딩에도 얹는다
  (HTTP 바인딩: `ElGraphWeb.MCP.Router`).

  `deps`:

    * `:tools`       — 노출할 `ElGraph.Action` 모듈 목록
    * `:server_info` — `%{"name" => ..., "version" => ...}` (initialize 응답)
    * `:context`     — Action `run/2`에 넘길 컨텍스트(선택, 기본 `%{}`)

  반환:

    * `{:result, map}`      — JSON-RPC `result`로 감쌀 값
    * `{:error, code, msg}` — JSON-RPC `error` (예: -32601 method not found, -32602 invalid params)
    * `:notification`       — 알림 메서드(`notifications/*`)는 응답 없음

  MCP 규약: **툴 실행 실패는 프로토콜 에러가 아니라** `isError: true` 결과로 돌려준다
  (모델이 오류를 보고 재시도할 수 있도록). 알 수 없는 툴/잘못된 메서드만 JSON-RPC error.
  """

  alias ElGraph.Action

  # 구현하는 MCP 스펙 리비전.
  @protocol_version "2025-06-18"

  @type deps :: %{
          required(:tools) => [module()],
          required(:server_info) => map(),
          optional(:context) => term()
        }
  @type result :: {:result, map()} | {:error, integer(), String.t()} | :notification

  @spec handle(String.t() | nil, map(), deps()) :: result()
  def handle("initialize", _params, deps) do
    {:result,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => deps.server_info
     }}
  end

  def handle("tools/list", _params, deps) do
    {:result, %{"tools" => Enum.map(deps.tools, &tool_descriptor/1)}}
  end

  def handle("tools/call", %{"name" => name} = params, deps) do
    arguments = Map.get(params, "arguments", %{})

    case Enum.find(deps.tools, &(&1.name() == name)) do
      nil -> {:error, -32602, "Unknown tool: #{name}"}
      module -> {:result, call_tool(module, arguments, Map.get(deps, :context, %{}))}
    end
  end

  def handle("notifications/" <> _rest, _params, _deps), do: :notification

  def handle(method, _params, _deps) when is_binary(method),
    do: {:error, -32601, "Method not found: #{method}"}

  def handle(_method, _params, _deps), do: {:error, -32600, "Invalid Request"}

  defp tool_descriptor(module) do
    spec = Action.to_tool_spec(module)
    %{"name" => spec.name, "description" => spec.description, "inputSchema" => spec.input_schema}
  end

  defp call_tool(module, arguments, context) do
    case Action.execute(module, arguments, context) do
      {:ok, result} -> %{"content" => [text(result)], "isError" => false}
      {:error, reason} -> %{"content" => [text(reason)], "isError" => true}
    end
  end

  defp text(term) when is_binary(term), do: %{"type" => "text", "text" => term}
  defp text(term), do: %{"type" => "text", "text" => inspect(term)}
end
