defmodule ElGraph.MCP.Client.Capabilities do
  @moduledoc """
  MCP **클라이언트 능력** — sampling / elicitation / roots (SPEC §4, 자주 누락되는 차별점).

  서버가 클라이언트에게 *역으로* 요청하는 기능들이다:

    * `sampling/createMessage` — 서버가 클라이언트의 LLM으로 보완 생성을 요청.
    * `elicitation/create`     — 서버가 사용자 입력을 요청.
    * `roots/list`             — 서버가 클라이언트가 노출한 파일시스템 root 목록을 조회.

  순수 디스패처다 — transport(예: `ElGraph.MCP.Client.StreamableHTTP`)가 서버 개시 요청을
  받으면 `handle/3`로 응답을 만든다. `advertise/1`은 제공된 핸들러만 initialize에 광고한다.

  핸들러 맵: `%{sampling: (params -> map), elicitation: (params -> map), roots: (-> [map])}`.
  """

  @type handlers :: %{
          optional(:sampling) => (map() -> map()),
          optional(:elicitation) => (map() -> map()),
          optional(:roots) => (-> [map()])
        }
  @type result :: {:result, map()} | {:error, integer(), String.t()}

  @doc "제공된 핸들러에 해당하는 클라이언트 capability 맵을 만든다(initialize용)."
  @spec advertise(handlers()) :: map()
  def advertise(handlers) when is_map(handlers) do
    %{}
    |> put_if(handlers, :sampling, "sampling", %{})
    |> put_if(handlers, :elicitation, "elicitation", %{})
    |> put_if(handlers, :roots, "roots", %{"listChanged" => false})
  end

  @doc "서버 개시 요청을 핸들러로 디스패치한다."
  @spec handle(String.t(), map(), handlers()) :: result()
  def handle("sampling/createMessage", params, handlers),
    do: dispatch(handlers, :sampling, fn fun -> fun.(params) end)

  def handle("elicitation/create", params, handlers),
    do: dispatch(handlers, :elicitation, fn fun -> fun.(params) end)

  def handle("roots/list", _params, handlers),
    do: dispatch(handlers, :roots, fn fun -> %{"roots" => fun.()} end)

  def handle(method, _params, _handlers),
    do: {:error, -32601, "Method not found: #{method}"}

  defp dispatch(handlers, key, run) do
    case Map.get(handlers, key) do
      nil -> {:error, -32601, "Client does not support #{key}"}
      fun -> {:result, run.(fun)}
    end
  end

  defp put_if(caps, handlers, key, string_key, value) do
    if Map.has_key?(handlers, key), do: Map.put(caps, string_key, value), else: caps
  end
end
