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
          optional(:context) => term(),
          optional(:resources) => [map()],
          optional(:prompts) => [map()]
        }
  @type result :: {:result, map()} | {:error, integer(), String.t()} | :notification

  @spec handle(String.t() | nil, map(), deps()) :: result()
  def handle("initialize", _params, deps) do
    {:result,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => capabilities(deps),
       "serverInfo" => deps.server_info
     }}
  end

  def handle("tools/list", _params, deps) do
    {:result, %{"tools" => Enum.map(deps.tools, &tool_descriptor/1)}}
  end

  def handle("resources/list", _params, deps) do
    {:result, %{"resources" => Enum.map(resources(deps), &resource_descriptor/1)}}
  end

  def handle("resources/read", %{"uri" => uri}, deps) do
    case Enum.find(resources(deps), &(&1.uri == uri)) do
      nil ->
        {:error, -32602, "Unknown resource: #{uri}"}

      resource ->
        case read_resource(resource) do
          {:ok, text} ->
            {:result,
             %{"contents" => [%{"uri" => uri, "mimeType" => mime_type(resource), "text" => text}]}}

          {:error, reason} ->
            {:error, -32603, "Resource read failed: #{inspect(reason)}"}
        end
    end
  end

  def handle("prompts/list", _params, deps) do
    {:result, %{"prompts" => Enum.map(prompts(deps), &prompt_descriptor/1)}}
  end

  def handle("prompts/get", %{"name" => name} = params, deps) do
    case Enum.find(prompts(deps), &(&1.name == name)) do
      nil -> {:error, -32602, "Unknown prompt: #{name}"}
      prompt -> {:result, render_prompt(prompt, Map.get(params, "arguments", %{}))}
    end
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

  defp capabilities(deps) do
    %{"tools" => %{}}
    |> maybe_capability(resources(deps), "resources")
    |> maybe_capability(prompts(deps), "prompts")
  end

  defp maybe_capability(caps, [], _key), do: caps
  defp maybe_capability(caps, [_ | _], key), do: Map.put(caps, key, %{})

  defp resources(deps), do: Map.get(deps, :resources, [])
  defp prompts(deps), do: Map.get(deps, :prompts, [])

  defp tool_descriptor(module) do
    spec = Action.to_tool_spec(module)
    %{"name" => spec.name, "description" => spec.description, "inputSchema" => spec.input_schema}
  end

  defp resource_descriptor(resource) do
    %{
      "uri" => resource.uri,
      "name" => resource.name,
      "description" => Map.get(resource, :description),
      "mimeType" => mime_type(resource)
    }
  end

  defp mime_type(resource), do: Map.get(resource, :mime_type, "text/plain")

  defp read_resource(resource) do
    case resource.read.() do
      {:ok, text} -> {:ok, text}
      {:error, _reason} = error -> error
      text when is_binary(text) -> {:ok, text}
    end
  end

  defp prompt_descriptor(prompt) do
    %{
      "name" => prompt.name,
      "description" => Map.get(prompt, :description),
      "arguments" => Map.get(prompt, :arguments, [])
    }
  end

  defp render_prompt(prompt, arguments) do
    messages =
      arguments
      |> prompt.render.()
      |> Enum.map(fn %{role: role, text: text} ->
        %{"role" => role, "content" => %{"type" => "text", "text" => text}}
      end)

    %{"description" => Map.get(prompt, :description), "messages" => messages}
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
