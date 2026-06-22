defmodule ElGraphWeb.A2A.JSONRPC do
  @moduledoc """
  A2A JSON-RPC 2.0 메서드 디스패치 (순수 — HTTP 무관, 단위 테스트 가능).

  `deps`는 실행에 필요한 의존성 맵이다:

    * `:graph`      — 호출할 컴파일된 ElGraph 그래프
    * `:task_store` — `{ElGraphWeb.TaskStore, ref}`의 `ref` (GenServer 서버)

  반환:

    * `{:result, map}`       — JSON-RPC `result`로 감쌀 값 (보통 A2A Task)
    * `{:error, code, msg}`  — JSON-RPC `error` 객체로 감쌀 값
    * `{:stream, enumerable}` — SSE로 흘려보낼 JSON-RPC result 프레임들

  지원 메서드: `message/send`, `tasks/get`, `message/stream`.
  """

  alias ElGraph.A2A
  alias ElGraphWeb.TaskStore

  @type deps :: %{
          required(:graph) => ElGraph.Graph.t(),
          required(:task_store) => TaskStore.ref(),
          optional(:caller) => term()
        }
  @type result :: {:result, map()} | {:error, integer(), String.t()} | {:stream, Enumerable.t()}

  @doc "JSON-RPC 메서드를 디스패치한다."
  @spec handle(String.t() | nil, map(), deps()) :: result()
  def handle("message/send", %{"message" => message}, deps) do
    result = ElGraph.invoke(deps.graph, A2A.message_to_input(message))
    task = build_task(result)
    :ok = TaskStore.put(deps.task_store, task, caller(deps))
    {:result, task}
  end

  def handle("tasks/get", %{"id" => id}, deps) do
    case TaskStore.get(deps.task_store, id, caller(deps)) do
      {:ok, task} -> {:result, task}
      :error -> {:error, -32001, "Task not found"}
    end
  end

  def handle("message/stream", %{"message" => message}, deps) do
    {:stream, stream_frames(deps.graph, message)}
  end

  def handle(nil, _params, _deps), do: {:error, -32600, "Invalid Request"}

  def handle(method, _params, _deps) when is_binary(method),
    do: {:error, -32601, "Method not found"}

  def handle(_method, _params, _deps), do: {:error, -32600, "Invalid Request"}

  ## Task 빌드

  defp build_task(result) do
    %{
      "id" => new_id(),
      "contextId" => new_id(),
      "status" => %{"state" => to_state(result)},
      "artifacts" => [%{"parts" => [%{"text" => inspect(result_payload(result))}]}],
      "history" => []
    }
  end

  defp to_state(result), do: A2A.to_task_state(result).state

  defp result_payload({:ok, state}), do: state
  defp result_payload({:error, reason}), do: reason
  defp result_payload({:interrupted, info}), do: info

  # 호출자별 Task 스코프용 식별자 — 인증 plug가 conn.assigns[:caller]로 싣고 라우터가 deps에 넣는다.
  defp caller(deps), do: Map.get(deps, :caller)

  # 추측 불가능한 Task id — 단조증가 정수(System.unique_integer)는 열거로 타 호출자 Task를
  # 노출시키므로 128비트 난수로 만든다.
  defp new_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  ## 스트리밍 — ElGraph 스트림 원소를 A2A status/artifact-update result 프레임으로 매핑

  defp stream_frames(graph, message) do
    input = A2A.message_to_input(message)
    task_id = new_id()
    ctx_id = new_id()

    graph
    |> ElGraph.stream(input)
    |> Stream.flat_map(&to_frame(&1, task_id, ctx_id))
  end

  defp to_frame(%{event: :node_start} = _el, task_id, ctx_id),
    do: [frame(status_update(task_id, ctx_id, "working"))]

  defp to_frame(%{event: {:token, delta}}, task_id, ctx_id),
    do: [frame(artifact_update(task_id, ctx_id, delta))]

  defp to_frame(%{event: {:done, result}}, task_id, ctx_id),
    do: [frame(status_update(task_id, ctx_id, to_state(result), final: true))]

  defp to_frame(%{event: {:down, _reason}}, task_id, ctx_id),
    do: [frame(status_update(task_id, ctx_id, "failed", final: true))]

  defp to_frame(_el, _task_id, _ctx_id), do: []

  defp status_update(task_id, ctx_id, state, opts \\ []) do
    %{
      "kind" => "status-update",
      "taskId" => task_id,
      "contextId" => ctx_id,
      "status" => %{"state" => state},
      "final" => Keyword.get(opts, :final, false)
    }
  end

  defp artifact_update(task_id, ctx_id, text) do
    %{
      "kind" => "artifact-update",
      "taskId" => task_id,
      "contextId" => ctx_id,
      "artifact" => %{"parts" => [%{"text" => text}]}
    }
  end

  defp frame(result), do: %{"jsonrpc" => "2.0", "id" => nil, "result" => result}
end
