defmodule ElGraph.AGUI do
  @moduledoc """
  AG-UI(Agent-User Interaction) 프로토콜 매핑 (트렌드 보고서 Tier 1).

  에이전트 실행을 사용자 인터페이스로 스트리밍하기 위한 순수 변환 계층이다.
  ElGraph 스트림 이벤트(`ElGraph.stream/3`의 `%{thread_id, step, node, event}` 원소)를
  AG-UI 표준 이벤트(타입 + camelCase 필드)로 변환한다. HTTP/SSE 서버는 이 매핑 위의
  얇은 계층으로 별도 패키지가 담당한다 — `ElGraph.A2A`와 동일한 패턴.

  AG-UI 이벤트 타입 (구현 범위):
    RUN_STARTED / RUN_FINISHED / RUN_ERROR — 실행 생명주기
    STEP_STARTED / STEP_FINISHED          — 노드(=step) 경계 (`:node_start`/`:node_end`)
    TEXT_MESSAGE_START / _CONTENT / _END  — 토큰 스트림 (`{:token, delta}`)
    TOOL_CALL_START / _ARGS / _END        — 툴 호출 (`{:tool_call, id, name, args}`)
    STATE_SNAPSHOT                        — 최종/중단 상태 (`{:done, result}`)

  토큰 메시지는 노드 단위로 프레이밍한다(노드 1개 = assistant 메시지 1개). `transform/3`이
  열린 메시지를 추적해 `:node_end`나 종료 이벤트 시 자동으로 닫는다.
  """

  @type event :: %{String.t() => term()}

  @doc """
  RUN_STARTED 이벤트.

      iex> ElGraph.AGUI.run_started("t1", "r1")["type"]
      "RUN_STARTED"
  """
  @spec run_started(String.t(), String.t()) :: event()
  def run_started(thread_id, run_id),
    do: %{"type" => "RUN_STARTED", "threadId" => thread_id, "runId" => run_id}

  @doc "RUN_FINISHED 이벤트."
  @spec run_finished(String.t(), String.t()) :: event()
  def run_finished(thread_id, run_id),
    do: %{"type" => "RUN_FINISHED", "threadId" => thread_id, "runId" => run_id}

  @doc """
  RUN_ERROR 이벤트.

      iex> ElGraph.AGUI.run_error("boom")["message"]
      "boom"
  """
  @spec run_error(String.t()) :: event()
  def run_error(message), do: %{"type" => "RUN_ERROR", "message" => message}

  @doc "STATE_SNAPSHOT 이벤트 — 임의 상태 스냅샷."
  @spec state_snapshot(term()) :: event()
  def state_snapshot(snapshot), do: %{"type" => "STATE_SNAPSHOT", "snapshot" => snapshot}

  @doc "STATE_DELTA 이벤트 — JSON Patch(RFC 6902) 연산 목록."
  @spec state_delta([map()]) :: event()
  def state_delta(ops) when is_list(ops), do: %{"type" => "STATE_DELTA", "delta" => ops}

  @doc "MESSAGES_SNAPSHOT 이벤트 — 전체 메시지 목록 스냅샷."
  @spec messages_snapshot([term()]) :: event()
  def messages_snapshot(messages) when is_list(messages),
    do: %{"type" => "MESSAGES_SNAPSHOT", "messages" => messages}

  @doc """
  CUSTOM 이벤트 — 프레임워크 밖 임의 이벤트(메트릭 등).

      iex> ElGraph.AGUI.custom("metric", 5)["value"]
      5
  """
  @spec custom(String.t(), term()) :: event()
  def custom(name, value), do: %{"type" => "CUSTOM", "name" => name, "value" => value}

  @doc """
  단일 ElGraph 스트림 원소를 AG-UI 이벤트로 무상태 매핑한다(best-effort). 메시지 프레이밍이
  필요 없는 경우용 — 완전한 시퀀스(START/END 프레이밍 포함)는 `transform/3`을 쓴다.
  매핑 불가 원소는 `:ignore`.
  """
  @spec encode(map()) :: {:ok, event()} | :ignore
  def encode(%{event: :node_start, node: node}), do: {:ok, step_started(node)}
  def encode(%{event: :node_end, node: node}), do: {:ok, step_finished(node)}
  def encode(%{event: {:token, delta}} = el), do: {:ok, text_content(el_message_id(el), delta)}
  def encode(%{event: {:done, {:ok, state}}}), do: {:ok, state_snapshot(state)}
  def encode(%{event: {:done, {:interrupted, info}}}), do: {:ok, state_snapshot(info)}
  def encode(%{event: {:done, {:error, reason}}}), do: {:ok, run_error(format_error(reason))}
  def encode(%{event: {:down, reason}}), do: {:ok, run_error(format_error(reason))}
  def encode(_element), do: :ignore

  @doc """
  ElGraph 스트림(Enumerable of `%{event: ...}`)을 AG-UI 이벤트 시퀀스로 변환한다.

  앞에 RUN_STARTED를 붙이고, 토큰을 메시지로 프레이밍하며, 종료(`{:done, _}`/`{:down, _}`)
  시 STATE_SNAPSHOT + RUN_FINISHED(또는 RUN_ERROR)로 마감한다. 입력이 lazy 스트림이면
  결과도 lazy다.
  """
  @spec transform(Enumerable.t(), String.t(), String.t()) :: Enumerable.t()
  def transform(stream, thread_id, run_id) do
    initial = %{thread_id: thread_id, run_id: run_id, open: nil, finished: false}

    Stream.concat([
      [run_started(thread_id, run_id)],
      Stream.transform(stream, fn -> initial end, &step/2, &last/1, fn _acc -> :ok end)
    ])
  end

  # 스트림이 명시적 종료 이벤트(`{:done, _}`/`{:down, _}`) 없이 소진되면 열린 메시지를 닫고
  # RUN_FINISHED로 마감한다 (이미 종료됐으면 무동작).
  defp last(%{finished: true} = acc), do: {[], acc}

  defp last(acc) do
    {close, acc} = close_open(acc)
    {close ++ [run_finished(acc.thread_id, acc.run_id)], %{acc | finished: true}}
  end

  # acc.open = 현재 열린 텍스트 메시지의 {node, message_id} 또는 nil
  defp step(%{event: :node_start, node: node}, acc),
    do: {[step_started(node)], acc}

  defp step(%{event: :node_end, node: node}, acc) do
    {close, acc} = close_open(acc)
    {close ++ [step_finished(node)], acc}
  end

  defp step(%{event: {:token, delta}, node: node} = el, acc) do
    {open_events, acc, mid} = ensure_open(acc, node, el)
    {open_events ++ [text_content(mid, delta)], acc}
  end

  defp step(%{event: {:tool_call, id, name, args}}, acc) do
    # 툴 호출은 진행 중 텍스트 메시지를 끊으므로 먼저 닫는다.
    {close, acc} = close_open(acc)
    {close ++ [tool_call_start(id, name), tool_call_args(id, args), tool_call_end(id)], acc}
  end

  defp step(%{event: {:done, result}}, acc), do: finish(result, acc)
  defp step(%{event: {:down, reason}}, acc), do: finish({:error, {:down, reason}}, acc)

  # 알려지지 않은 사용자 이벤트는 무시한다.
  defp step(%{event: _other}, acc), do: {[], acc}

  ## 종료 처리

  defp finish(_result, %{finished: true} = acc), do: {[], acc}

  defp finish(result, acc) do
    {close, acc} = close_open(acc)
    acc = %{acc | finished: true}
    {close ++ terminal_events(result, acc), acc}
  end

  defp terminal_events({:error, reason}, _acc), do: [run_error(format_error(reason))]

  defp terminal_events({:interrupted, info}, acc),
    do: [state_snapshot(info), run_finished(acc.thread_id, acc.run_id)]

  defp terminal_events({:ok, state}, acc),
    do: [state_snapshot(state), run_finished(acc.thread_id, acc.run_id)]

  # {:done, _}가 도착하지 않고 스트림이 끝나는 경우는 transform이 RUN_FINISHED를 붙이지
  # 않는다 — 호출자가 명시적 종료 이벤트를 보장한다. 여기 도달하는 다른 result는 그대로 스냅샷.
  defp terminal_events(other, acc),
    do: [state_snapshot(other), run_finished(acc.thread_id, acc.run_id)]

  ## 메시지 프레이밍 헬퍼

  defp ensure_open(%{open: {node, mid}} = acc, node, _el), do: {[], acc, mid}

  defp ensure_open(acc, node, el) do
    {close, acc} = close_open(acc)
    mid = message_id(acc.run_id, node, el)
    {close ++ [text_start(mid)], %{acc | open: {node, mid}}, mid}
  end

  defp close_open(%{open: nil} = acc), do: {[], acc}
  defp close_open(%{open: {_node, mid}} = acc), do: {[text_end(mid)], %{acc | open: nil}}

  defp message_id(run_id, node, el) do
    step = Map.get(el, :step, 0)
    "#{run_id}-#{node}-#{step}"
  end

  defp el_message_id(el) do
    "#{Map.get(el, :node, "msg")}-#{Map.get(el, :step, 0)}"
  end

  ## 이벤트 생성자

  defp step_started(node), do: %{"type" => "STEP_STARTED", "stepName" => to_string(node)}
  defp step_finished(node), do: %{"type" => "STEP_FINISHED", "stepName" => to_string(node)}

  defp text_start(mid),
    do: %{"type" => "TEXT_MESSAGE_START", "messageId" => mid, "role" => "assistant"}

  defp text_content(mid, delta),
    do: %{"type" => "TEXT_MESSAGE_CONTENT", "messageId" => mid, "delta" => delta}

  defp text_end(mid), do: %{"type" => "TEXT_MESSAGE_END", "messageId" => mid}

  defp tool_call_start(id, name),
    do: %{"type" => "TOOL_CALL_START", "toolCallId" => id, "toolCallName" => name}

  defp tool_call_args(id, args),
    do: %{"type" => "TOOL_CALL_ARGS", "toolCallId" => id, "delta" => encode_args(args)}

  defp tool_call_end(id), do: %{"type" => "TOOL_CALL_END", "toolCallId" => id}

  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args), do: JSON.encode!(args)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
