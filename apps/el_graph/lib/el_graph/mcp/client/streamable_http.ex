defmodule ElGraph.MCP.Client.StreamableHTTP do
  @moduledoc """
  MCP **Streamable HTTP** 클라이언트 transport (`ElGraph.MCP.Client` 구현, SPEC §4).

  외부 MCP 서버를 단일 엔드포인트로 호출한다 — JSON-RPC 2.0을 `POST`하고 JSON 응답을 받는다
  (서버가 SSE로 응답하는 스트리밍 메서드는 현재 미지원, 요청/응답 메서드 중심).

      {:ok, handle} = ElGraph.MCP.Client.StreamableHTTP.connect("https://host/mcp")
      {:ok, tools}  = ElGraph.MCP.tools({ElGraph.MCP.Client.StreamableHTTP, handle})

  핸들은 `%{url, req_options, session_id, protocol_version}`. `connect/2`가 `initialize`
  핸드셰이크를 수행하고(서버가 주면 `mcp-session-id` 캡처) `notifications/initialized`를
  보낸다. 이후 `list_tools/1`·`call_tool/3`은 같은 핸들로 요청한다.

  `:capabilities` 옵션(`ElGraph.MCP.Client.Capabilities`의 핸들러 맵)을 주면 initialize에
  클라이언트 능력(sampling/elicitation/roots)을 광고한다.
  """

  @behaviour ElGraph.MCP.Client

  alias ElGraph.MCP.Client.Capabilities

  @type handle :: %{
          url: String.t(),
          req_options: keyword(),
          session_id: String.t() | nil,
          protocol_version: String.t() | nil
        }

  @protocol_version "2025-06-18"

  @doc "MCP 서버에 연결하고 initialize 핸드셰이크를 수행한다."
  @spec connect(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def connect(url, opts \\ []) do
    handle = %{
      url: url,
      req_options: Keyword.get(opts, :req_options, []),
      session_id: nil,
      protocol_version: nil
    }

    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => Capabilities.advertise(Keyword.get(opts, :capabilities, %{})),
      "clientInfo" =>
        Keyword.get(opts, :client_info, %{"name" => "el_graph", "version" => "0.2.0"})
    }

    case post(handle, "initialize", params) do
      {:ok, result, session_id} ->
        handle = %{handle | session_id: session_id, protocol_version: result["protocolVersion"]}
        notify(handle, "notifications/initialized")
        {:ok, handle}

      {:error, _reason} = error ->
        error
    end
  end

  @impl ElGraph.MCP.Client
  def list_tools(handle) do
    with {:ok, result, _sid} <- post(handle, "tools/list", %{}) do
      {:ok, result["tools"] || []}
    end
  end

  @impl ElGraph.MCP.Client
  def call_tool(handle, name, args) do
    with {:ok, result, _sid} <- post(handle, "tools/call", %{"name" => name, "arguments" => args}) do
      {:ok, result}
    end
  end

  ## JSON-RPC over HTTP

  defp post(handle, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => request_id(), "method" => method, "params" => params}

    case Req.post(
           handle.url,
           [json: body, headers: headers(handle), retry: false] ++ handle.req_options
         ) do
      {:ok, %Req.Response{status: status, body: %{"result" => result}} = resp}
      when status in 200..299 ->
        {:ok, result, session_id(resp)}

      {:ok, %Req.Response{body: %{"error" => %{"code" => code, "message" => msg}}}} ->
        {:error, {:rpc_error, code, msg}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:transport_error, exception}}
    end
  end

  # 알림(응답 불필요) — 실패는 무시한다.
  defp notify(handle, method) do
    body = %{"jsonrpc" => "2.0", "method" => method, "params" => %{}}

    Req.post(
      handle.url,
      [json: body, headers: headers(handle), retry: false] ++ handle.req_options
    )

    :ok
  end

  defp headers(%{session_id: nil}), do: []
  defp headers(%{session_id: sid}), do: [{"mcp-session-id", sid}]

  defp session_id(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "mcp-session-id") do
      [sid | _] -> sid
      [] -> nil
    end
  end

  defp request_id, do: System.unique_integer([:positive])
end
