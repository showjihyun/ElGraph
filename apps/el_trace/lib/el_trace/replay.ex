defmodule ElTrace.Replay do
  @moduledoc """
  ElTrace #4: 체크포인트 time-travel 재개 — ElGraph만의 킬러 기능.

  Langfuse는 trace를 *보여줄* 뿐이지만, ElGraph는 체크포인트로 임의 과거 step의 완전한
  상태를 안다. `from/5`는 그 step의 상태로 **새 thread를 분기(fork)**해 재실행한다 —
  원래 thread는 보존되므로 "여기서 다르게 가보기"가 가능하다.

      ElTrace.Replay.from(graph, checkpointer, "thread-1", 2, as: "thread-1-fork")
  """

  @doc """
  `source_thread`의 `from_step` 체크포인트 상태에서 새 thread로 재실행한다.

  옵션 `:as`로 분기 thread_id 지정(기본 `"<source>-replay-<step>"`).
  원래 thread의 체크포인트는 건드리지 않는다.
  """
  @spec from({module(), term()}, String.t(), non_neg_integer(), ElGraph.Graph.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:interrupted, map()}
  def from({mod, config}, source_thread, from_step, graph, opts \\ []) do
    new_thread = Keyword.get(opts, :as, "#{source_thread}-replay-#{from_step}")

    case mod.get(config, source_thread, from_step) do
      {:ok, checkpoint} ->
        # 분기 thread로 실행 — 원래 thread의 체크포인트는 새 thread_id를 쓰므로 보존된다.
        forked = %{checkpoint | thread_id: new_thread}

        ElGraph.Executor.resume_from(graph, forked,
          checkpointer: {mod, config},
          thread_id: new_thread
        )

      :not_found ->
        {:error, {:no_checkpoint, source_thread, from_step}}
    end
  end
end
