defmodule ElTrace.TestNodes do
  @moduledoc false
  # el_trace 테스트 전용 노드. el_graph의 test/support는 앱 경계를 넘어 보이지 않으므로
  # ElTrace 테스트가 쓰는 최소 노드만 여기 둔다.
  alias ElGraph.Ctx

  def noop(_state, _ctx), do: %{}

  def ask(_state, ctx) do
    answer = Ctx.interrupt(ctx, %{question: "name?"})
    %{result: answer}
  end
end
