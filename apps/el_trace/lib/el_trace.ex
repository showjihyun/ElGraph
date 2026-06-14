defmodule ElTrace do
  @moduledoc """
  ElTrace 공개 API — 호스트 앱이 의존성으로 끌어다 쓰는 진입점.

  ElTrace는 ElGraph 체크포인트가 아는 인과(인터럽트 가시성·thread 생애·time-travel 분기)를
  브라우저에서 보여주는 별도 앱이다. 호스트 앱은 그래프를 실행한 뒤 `observe/4`로 등록하면
  ElTrace LiveView(`/`)에 실시간으로 나타난다 — 거기서 승인/거절(resume)·여기서 분기(Replay)를 할 수 있다.

      cp = {ElGraph.Checkpointer.ETS, ETS.config(pid)}
      {:interrupted, _} = ElGraph.invoke(graph, input, checkpointer: cp, thread_id: "t1")
      ElTrace.observe("t1", graph, cp)
      # 브라우저에서 http://localhost:4000

  범용 trace(span/토큰)는 Langfuse에 위임하고, ElTrace는 체크포인트 인과만 다룬다.
  """

  alias ElTrace.{Replay, Sessions, Timeline}

  @doc """
  실행 thread를 ElTrace UI에 등록한다. 컴파일된 `graph`와 `checkpointer`를 함께 보관해야
  UI에서 resume·분기를 수행할 수 있다 (체크포인트에는 그래프 정의가 없으므로).

  옵션 `:parent`로 분기(fork)의 부모 thread를 기록한다.
  """
  @spec observe(String.t(), ElGraph.Graph.t(), {module(), term()}, keyword()) :: :ok
  def observe(thread_id, graph, checkpointer, opts \\ []) do
    Sessions.register(table(), thread_id, graph, checkpointer, opts)
  end

  @doc "등록된 thread의 타임라인 이벤트(체크포인트 생애). 미등록이면 `:error`."
  @spec timeline(String.t()) :: {:ok, [Timeline.event()]} | :error
  def timeline(thread_id) do
    case Sessions.get(table(), thread_id) do
      {:ok, %{checkpointer: cp}} -> {:ok, Timeline.build(cp, thread_id)}
      :error -> :error
    end
  end

  @doc """
  `source_thread`의 `from_step` 체크포인트에서 새 thread로 분기(time-travel fork)하고 등록한다.
  UI의 "여기서 분기" 버튼과 같은 동작 — 원본 thread는 보존된다. 분기 후 `ElGraph.resume/2`로
  다른 선택(예: "거절")을 주입하면 "if 시나리오"(승인↔거절)를 안전하게 탐색할 수 있다.

  옵션 `:as`로 분기 thread_id를 지정한다(기본 `"<source>-fork-<step>"`).
  분기 thread는 부모(`source_thread`) 계보와 함께 UI에 등록된다.

      {:ok, fork_id, {:interrupted, _}} = ElTrace.fork("t1", 1, as: "t1-거절")
      ElGraph.resume(graph, checkpointer: cp, thread_id: fork_id, resume: "거절")

  `source_thread`가 등록돼 있지 않으면 `:error`.
  """
  @spec fork(String.t(), non_neg_integer(), keyword()) :: {:ok, String.t(), term()} | :error
  def fork(source_thread, from_step, opts \\ []) do
    case Sessions.get(table(), source_thread) do
      {:ok, %{graph: graph, checkpointer: cp}} ->
        fork_id = Keyword.get(opts, :as, "#{source_thread}-fork-#{from_step}")
        result = Replay.from(cp, source_thread, from_step, graph, as: fork_id)
        Sessions.register(table(), fork_id, graph, cp, parent: source_thread)
        {:ok, fork_id, result}

      :error ->
        :error
    end
  end

  defp table, do: Sessions.table(Sessions)
end
