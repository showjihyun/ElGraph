defmodule ElGraph.Checkpointer do
  @moduledoc """
  체크포인트 영속화 behaviour (SPEC §3.5).

  `config`는 어댑터별 핸들(ETS 테이블 참조, DB 풀 설정 등)이며 실행기는 내용을 모른다.
  어댑터 적합성은 `ElGraph.CheckpointerContract` 공유 테스트로 검증한다.
  """

  alias ElGraph.Checkpoint

  @type config :: term()
  @type thread_id :: String.t()
  @type step :: non_neg_integer()
  # 실행기는 제어 지시를 함께 보존하므로 값은 `map()`(M1 형태) 또는 `{update, control}` 튜플.
  @type node_write :: {atom(), map() | {map(), term()}}

  @doc "체크포인트를 저장한다. 같은 (thread_id, step)은 덮어쓴다."
  @callback put(config(), Checkpoint.t()) :: :ok | {:error, term()}

  @doc "체크포인트를 조회한다. `:latest`는 해당 thread의 최고 step."
  @callback get(config(), thread_id(), :latest | step()) :: {:ok, Checkpoint.t()} | :not_found

  @doc "superstep 내 완료된 노드들의 쓰기를 보존한다 (부분 실패 재개용 pending writes)."
  @callback put_writes(config(), thread_id(), step(), [node_write()]) :: :ok | {:error, term()}

  @doc "보존된 pending writes를 조회한다. 없으면 `[]`."
  @callback get_writes(config(), thread_id(), step()) :: [node_write()]

  @doc "thread의 체크포인트 메타데이터를 step 오름차순으로 반환한다."
  @callback list(config(), thread_id()) :: [%{step: step(), version: pos_integer()}]
end
