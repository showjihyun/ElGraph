defmodule ElGraph.Graph do
  @moduledoc """
  그래프 정의 구조체. `ElGraph`의 빌더 함수로 구성하고 `ElGraph.compile/2`로 검증한다.

  체크포인트에는 절대 직렬화되지 않는다 — 그래프는 항상 코드에서 재구성된다 (SPEC §3.5).
  """

  defstruct state_def: %{},
            nodes: %{},
            edges: %{},
            routers: %{},
            entry: nil

  @typedoc "MFA + 인자 리스트 `{module, fun, extra_args}` (`mfa()`의 arity가 아니라 인자 리스트)"
  @type mfargs :: {module(), atom(), [term()]}

  @typedoc "노드 구현: MFA(+인자) 또는 2-인자 함수 `(state, ctx)`"
  @type node_run :: mfargs() | (map(), ElGraph.Ctx.t() -> term())

  @typedoc "조건부 엣지 라우터: MFA(+인자) 또는 1-인자 함수 `(state) -> 노드 | :end`"
  @type router :: mfargs() | (map() -> atom())

  @type t :: %__MODULE__{
          state_def: %{atom() => %{default: term(), reducer: mfargs() | function() | nil}},
          nodes: %{atom() => %{run: node_run(), opts: keyword()}},
          edges: %{atom() => [atom()]},
          routers: %{atom() => router()},
          entry: atom() | nil
        }
end
