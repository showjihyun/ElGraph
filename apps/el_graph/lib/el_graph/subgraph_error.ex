defmodule ElGraph.SubgraphError do
  @moduledoc "서브그래프 노드의 내부 실행이 `{:ok, _}`로 끝나지 않았을 때 발생한다."
  defexception [:result]

  @impl true
  def message(%__MODULE__{result: result}) do
    "subgraph execution did not succeed: #{inspect(result)}"
  end
end
