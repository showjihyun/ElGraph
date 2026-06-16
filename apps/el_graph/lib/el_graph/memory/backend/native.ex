defmodule ElGraph.Memory.Backend.Native do
  @moduledoc """
  코어 임베더 기반 기억 백엔드 — 외부 의존 0.

  `ElGraph.Memory` 위의 얇은 어댑터다: `remember`는 episodic 로그에 기록하고,
  `recall`은 `recall_relevant/4`(코사인 유사도)로 회수한다.

  config: `%{memory: ElGraph.Memory.t(), embedder: module()}`.
  `:scope`/`:limit`은 `recall` 옵션으로 넘긴다(기본 scope `"episodic"`).
  """

  @behaviour ElGraph.Memory.Backend

  alias ElGraph.Memory

  @impl true
  def remember(%{memory: %Memory{} = mem}, ns, text, opts) when is_binary(text) do
    Memory.record_episode(mem, ns, text, opts)
  end

  @impl true
  def recall(%{memory: %Memory{} = mem, embedder: embedder}, ns, query, opts) do
    opts = Keyword.put_new(opts, :embedder, embedder)
    {:ok, Memory.recall_relevant(mem, ns, query, opts)}
  end
end
