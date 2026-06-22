defmodule ElGraph.ActionTest do
  use ExUnit.Case, async: true

  alias ElGraph.TestActions.{Failing, Search}

  # 모든 type_schema/1 절을 to_tool_spec(공개 API)로 한 번에 통과시키기 위한 액션.
  defmodule AllTypes do
    use ElGraph.Action,
      name: "all_types",
      description: "every type_schema branch",
      schema: [
        b: [type: :boolean],
        pi: [type: :pos_integer],
        nn: [type: :non_neg_integer],
        f: [type: :float],
        a: [type: :atom],
        m: [type: :map],
        l: [type: {:list, :string}],
        choice: [type: {:in, [:x, :y]}],
        num_choice: [type: {:in, [1, 2]}],
        anything: [type: :any]
      ]

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  describe "metadata" do
    test "exposes name, description, and schema from use options" do
      assert "web_search" = Search.name()
      assert "웹을 검색합니다" = Search.description()
      assert [query: _query_spec, limit: _limit_spec] = Search.schema()
    end
  end

  describe "validate/1 (SPEC §4)" do
    test "validates atom-keyed params and applies defaults" do
      assert {:ok, %{query: "q", limit: 5}} = Search.validate(%{query: "q"})
    end

    test "accepts string-keyed params (LLM tool-call JSON)" do
      assert {:ok, %{query: "q", limit: 2}} = Search.validate(%{"query" => "q", "limit" => 2})
    end

    test "rejects missing required params" do
      assert {:error, _reason} = Search.validate(%{})
    end

    test "rejects wrong types" do
      assert {:error, _reason} = Search.validate(%{query: 123})
    end

    test "rejects unknown params" do
      assert {:error, _reason} = Search.validate(%{"query" => "q", "bogus" => 1})
    end
  end

  describe "execute/2" do
    test "validates then runs" do
      assert {:ok, %{results: ["r:q:5"]}} = Search.execute(%{query: "q"}, %{})
    end

    test "does not run on invalid params" do
      assert {:error, _reason} = Search.execute(%{}, %{})
    end
  end

  describe "to_tool_spec/0 (SPEC §4: 스키마 하나에서 검증 + tool 스펙 동시 생성)" do
    test "generates an LLM tool spec with a JSON Schema input" do
      assert %{
               name: "web_search",
               description: "웹을 검색합니다",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "검색어"},
                   "limit" => %{"type" => "integer"} = limit_schema
                 },
                 "required" => ["query"]
               }
             } = Search.to_tool_spec()

      assert limit_schema["description"] == "최대 결과 수"
    end

    test "maps every NimbleOptions type to its JSON Schema shape" do
      %{input_schema: %{"properties" => props}} = AllTypes.to_tool_spec()

      assert props["b"] == %{"type" => "boolean"}
      assert props["pi"] == %{"type" => "integer"}
      assert props["nn"] == %{"type" => "integer"}
      assert props["f"] == %{"type" => "number"}
      assert props["a"] == %{"type" => "string"}
      assert props["m"] == %{"type" => "object"}
      assert props["l"] == %{"type" => "array", "items" => %{"type" => "string"}}
      # {:in, _} → enum; atom choices stringify, integer choices pass through (to_json_value).
      assert props["choice"] == %{"enum" => ["x", "y"]}
      assert props["num_choice"] == %{"enum" => [1, 2]}
      # unknown/unmapped type → empty schema (the _other catchall).
      assert props["anything"] == %{}
    end
  end

  describe "to_node/1" do
    test "returns an MFA (durable-graph friendly, SPEC §3.2)" do
      assert {ElGraph.Action, :run_as_node, [Search]} = ElGraph.Action.to_node(Search)
    end

    test "runs the action as a graph node, taking params from state" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:query)
        |> ElGraph.state(:results)
        |> ElGraph.add_node(:search, ElGraph.Action.to_node(Search))
        |> ElGraph.compile(entry: :search)

      assert {:ok, %{results: ["r:q:5"]}} = ElGraph.invoke(graph, %{query: "q"})
    end

    test "action errors surface as node crashes with ActionError" do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:fail, ElGraph.Action.to_node(Failing))
        |> ElGraph.compile(entry: :fail)

      assert {:error,
              {:node_crashed, :fail, %ElGraph.ActionError{action: Failing, reason: :boom}}} =
               ElGraph.invoke(graph, %{})
    end
  end
end
