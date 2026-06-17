defmodule ElGraph.MCP.Client.Receiver do
  @moduledoc """
  MCP **양방향 수신 루프** — 서버 개시 요청(sampling/elicitation/roots)을 SSE로 받아 응답한다.

  Streamable HTTP에서 서버→클라이언트 요청은 SSE 이벤트로 도착한다. 이 모듈은 SSE 청크를
  파싱(`ElGraph.LLM.SSE` 재사용)해 각 JSON-RPC 메시지를 `ElGraph.MCP.Client.Capabilities`로
  처리하고, 응답이 필요한 요청이면 응답 JSON을 `respond` 콜백으로 되돌려보낸다
  (`ElGraph.MCP.Client.StreamableHTTP.listen/3`가 그 콜백으로 서버에 POST한다).

  순수 로직(파싱·디스패치)은 transport와 분리돼 있어 단위 테스트가 쉽다.
  """

  alias ElGraph.LLM.SSE
  alias ElGraph.MCP.Client.Capabilities

  @doc """
  SSE 청크 스트림을 소비하며, 서버 요청마다 `respond.(response_json)`을 호출한다.
  `chunks`는 SSE 바이트 청크의 Enumerable, `respond`는 응답 JSON 1-인자 콜백.
  """
  @spec run(Enumerable.t(), Capabilities.handlers(), (binary() -> any())) :: :ok
  def run(chunks, handlers, respond) do
    Enum.reduce(chunks, "", fn chunk, buffer ->
      {payloads, rest} = SSE.parse(buffer, chunk)

      Enum.each(payloads, fn json ->
        case handle_message(json, handlers) do
          {:respond, response} -> respond.(response)
          :ignore -> :ok
        end
      end)

      rest
    end)

    :ok
  end

  @doc """
  서버 메시지(JSON) 하나를 처리한다. id 있는 요청이면 `{:respond, response_json}`,
  알림/응답/파싱 실패면 `:ignore`.
  """
  @spec handle_message(binary(), Capabilities.handlers()) :: {:respond, binary()} | :ignore
  def handle_message(json, handlers) do
    case Jason.decode(json) do
      {:ok, %{"method" => method, "id" => id} = message} ->
        params = Map.get(message, "params", %{})
        {:respond, envelope(id, Capabilities.handle(method, params, handlers))}

      _other ->
        :ignore
    end
  end

  defp envelope(id, {:result, result}),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp envelope(id, {:error, code, message}),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })
end
