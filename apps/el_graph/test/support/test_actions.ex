defmodule ElGraph.TestActions.Search do
  @moduledoc false
  use ElGraph.Action,
    name: "web_search",
    description: "웹을 검색합니다",
    schema: [
      query: [type: :string, required: true, doc: "검색어"],
      limit: [type: :integer, default: 5, doc: "최대 결과 수"]
    ]

  @impl true
  def run(params, _context), do: {:ok, %{results: ["r:#{params.query}:#{params.limit}"]}}
end

defmodule ElGraph.TestActions.Failing do
  @moduledoc false
  use ElGraph.Action,
    name: "fail",
    description: "always fails",
    schema: []

  @impl true
  def run(_params, _context), do: {:error, :boom}
end
