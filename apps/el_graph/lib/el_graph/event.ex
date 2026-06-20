defmodule ElGraph.Event do
  @moduledoc """
  `ElGraph.stream/3`가 내보내는 **이벤트 봉투** — 한 곳에서 선언되는 인터페이스 (SPEC §3.7).

  스트림 원소의 형태는 여러 소비자가 의존한다 — `ElGraph.AGUI`(AG-UI 변환), `ElGraph.A2A`,
  `ElGraph.OTel`, `el_graph_web`(SSE), `el_trace`. 예전엔 이 봉투가 세 곳(`Ctx.emit`,
  실행기 생명주기 emit, `Runner`의 종료 이벤트)에서 inline 맵으로 따로 만들어졌고 선언·계약
  테스트가 없었다. 이제 형태는 여기서 정의되고 빌더로만 만들어지며, 생산자 드리프트는
  계약 테스트가 잡는다.

  두 변형:

    * `node_event` — 노드 경계(`:node_start`/`:node_end`)·토큰(`{:token, delta}`)·툴 호출·
      사용자 `Ctx.emit/2` 이벤트. `thread_id`/`step`/`node` 포함.
    * `run_event` — 실행 종료(`{:done, result}` 또는 `{:down, reason}`). `Runner`가 만들며
      `step`/`node`가 없다.
  """

  @typedoc "노드 단위 이벤트 — step·node 포함."
  @type node_event :: %{
          thread_id: String.t(),
          step: non_neg_integer(),
          node: atom(),
          event: term()
        }

  @typedoc "실행 종료 이벤트 — step·node 없음."
  @type run_event :: %{thread_id: String.t(), event: {:done, term()} | {:down, term()}}

  @type t :: node_event() | run_event()

  @doc "노드 이벤트 봉투. `Ctx.emit/2`와 실행기 생명주기 이벤트가 쓴다."
  @spec node(String.t(), non_neg_integer(), atom(), term()) :: node_event()
  def node(thread_id, step, node, event),
    do: %{thread_id: thread_id, step: step, node: node, event: event}

  @doc "실행 완료 봉투. `Runner`가 최종 결과를 스트림에 흘릴 때 쓴다."
  @spec done(String.t(), term()) :: run_event()
  def done(thread_id, result), do: %{thread_id: thread_id, event: {:done, result}}

  @doc "실행 비정상 종료(러너 DOWN) 봉투."
  @spec down(String.t(), term()) :: run_event()
  def down(thread_id, reason), do: %{thread_id: thread_id, event: {:down, reason}}
end
