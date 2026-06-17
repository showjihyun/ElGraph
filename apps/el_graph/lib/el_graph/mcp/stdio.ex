defmodule ElGraph.MCP.Stdio do
  @moduledoc """
  MCP 서버 **stdio transport** 바인딩 — ElGraph Action을 CLI MCP 서버로 노출한다.

  `ElGraph.MCP.Server` 순수 디스패치 위의 얇은 stdio 계층. MCP stdio 규약대로
  **줄 단위(newline-delimited) JSON-RPC**: stdin에서 한 줄에 메시지 하나를 읽어 처리하고
  응답을 stdout에 한 줄로 쓴다(알림은 무응답). 응답 JSON에는 내장 개행이 없다.

      # 호스트가 escript / `mix run`에서:
      ElGraph.MCP.Stdio.serve(%{tools: [MyApp.SearchAction], server_info: %{"name" => "myapp", "version" => "1.0"}})

  `:input`/`:output`으로 IO 디바이스를 주입할 수 있다(기본 `:standard_io`) — 테스트는 `StringIO`.
  """

  alias ElGraph.MCP.Server

  @doc "stdin(또는 `:input`)에서 메시지를 읽어 처리하는 루프. EOF까지 블록한다."
  @spec serve(Server.deps(), keyword()) :: :ok | {:error, term()}
  def serve(deps, opts \\ []) do
    input = Keyword.get(opts, :input, :standard_io)
    output = Keyword.get(opts, :output, :standard_io)
    loop(input, output, deps)
  end

  defp loop(input, output, deps) do
    case IO.read(input, :line) do
      :eof ->
        :ok

      {:error, _reason} = error ->
        error

      line ->
        case process_line(line, deps) do
          :notification -> :ok
          {:reply, json} -> IO.puts(output, json)
        end

        loop(input, output, deps)
    end
  end

  @doc """
  한 줄(JSON-RPC 메시지)을 처리한다 — 응답 JSON 문자열(`{:reply, json}`) 또는
  응답 없음(`:notification`, 알림/빈 줄). 파싱 실패는 JSON-RPC `-32700` 응답.
  """
  @spec process_line(binary(), Server.deps()) :: {:reply, binary()} | :notification
  def process_line(line, deps) do
    case String.trim(line) do
      "" -> :notification
      trimmed -> decode_and_dispatch(trimmed, deps)
    end
  end

  defp decode_and_dispatch(json, deps) do
    case Jason.decode(json) do
      {:ok, message} -> dispatch(message, deps)
      {:error, _reason} -> {:reply, error_envelope(nil, -32700, "Parse error")}
    end
  end

  defp dispatch(message, deps) do
    id = Map.get(message, "id")

    case Server.handle(Map.get(message, "method"), Map.get(message, "params", %{}), deps) do
      :notification -> :notification
      {:result, result} -> {:reply, result_envelope(id, result)}
      {:error, code, msg} -> {:reply, error_envelope(id, code, msg)}
    end
  end

  defp result_envelope(id, result),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error_envelope(id, code, message),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })
end
