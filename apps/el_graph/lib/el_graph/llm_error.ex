defmodule ElGraph.LLMError do
  @moduledoc "LLM 호출 실패. agent 노드를 crash시키므로 노드 `retry:` 정책과 결합된다."
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}), do: "LLM call failed: #{inspect(reason)}"
end
