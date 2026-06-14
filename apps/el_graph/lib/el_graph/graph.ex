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

  @typedoc "노드 구현: MFA 또는 2-인자 함수 `(state, ctx)`"
  @type node_run :: {module(), atom(), [term()]} | (map(), ElGraph.Ctx.t() -> term())

  @type t :: %__MODULE__{
          state_def: %{atom() => %{default: term(), reducer: mfa() | function() | nil}},
          nodes: %{atom() => %{run: node_run(), opts: keyword()}},
          edges: %{atom() => [atom()]},
          routers: %{atom() => mfa() | (map() -> atom())},
          entry: atom() | nil
        }
end
