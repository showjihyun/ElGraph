defmodule ElGraph.ActionError do
  @moduledoc "Action 실행 실패. 그래프 노드로 실행 중이면 `{:node_crashed, node, %__MODULE__{}}`로 나타난다."
  defexception [:action, :reason]

  @impl true
  def message(%__MODULE__{action: action, reason: reason}) do
    "action #{inspect(action)} failed: #{inspect(reason)}"
  end
end
