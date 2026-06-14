defmodule ElGraph.Action do
  @moduledoc """
  스키마 검증되는 작업 단위 (SPEC §4).

  스키마 하나(NimbleOptions)에서 **파라미터 검증과 LLM tool-calling 스펙을 동시에
  생성**한다 — 이것이 Action 추상화의 존재 이유다.

      defmodule MyApp.SearchAction do
        use ElGraph.Action,
          name: "web_search",
          description: "웹을 검색합니다",
          schema: [query: [type: :string, required: true, doc: "검색어"]]

        @impl true
        def run(params, _context), do: {:ok, %{results: search(params.query)}}
      end

  `use` 시점에 스키마가 컴파일·검증되므로 잘못된 스키마는 컴파일 에러다.
  파라미터는 atom 키와 문자열 키(LLM tool-call JSON) 맵을 모두 받는다.

  그래프 노드로 쓰려면 `to_node/1` — MFA를 반환하므로 durable 그래프
  제약(SPEC §3.2)과 호환되며, 파라미터는 상태에서 스키마 키만 투영해 얻는다
  (`nil` 값은 미설정으로 간주해 제외).
  """

  @callback run(params :: map(), context :: term()) :: {:ok, map()} | {:error, term()}
  @callback compensate(params :: map(), error :: term(), context :: term()) :: :ok
  @optional_callbacks compensate: 3

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour ElGraph.Action

      @el_graph_action_name Keyword.fetch!(opts, :name)
      @el_graph_action_description Keyword.fetch!(opts, :description)
      @el_graph_action_schema Keyword.fetch!(opts, :schema)
      @el_graph_action_compiled NimbleOptions.new!(@el_graph_action_schema)

      @doc "Action 이름 (LLM tool 이름으로 쓰인다)."
      def name, do: @el_graph_action_name

      @doc "Action 설명 (LLM tool 설명으로 쓰인다)."
      def description, do: @el_graph_action_description

      @doc "원본 스키마 정의."
      def schema, do: @el_graph_action_schema

      @doc false
      def __compiled_schema__, do: @el_graph_action_compiled

      @doc "파라미터를 검증하고 기본값을 적용한다."
      def validate(params), do: ElGraph.Action.validate(__MODULE__, params)

      @doc "검증 후 `run/2`를 실행한다."
      def execute(params, context), do: ElGraph.Action.execute(__MODULE__, params, context)

      @doc "LLM tool-calling 스펙(JSON Schema)을 생성한다."
      def to_tool_spec, do: ElGraph.Action.to_tool_spec(__MODULE__)
    end
  end

  @doc "파라미터(atom 또는 문자열 키 맵)를 검증하고 기본값이 적용된 atom 키 맵을 반환한다."
  @spec validate(module(), map()) :: {:ok, map()} | {:error, term()}
  def validate(module, params) when is_map(params) do
    with {:ok, keyword} <- params_to_keyword(module, params),
         {:ok, validated} <- NimbleOptions.validate(keyword, module.__compiled_schema__()) do
      {:ok, Map.new(validated)}
    end
  end

  @doc "검증 후 모듈의 `run/2`를 호출한다. 검증 실패 시 `run/2`는 호출되지 않는다."
  @spec execute(module(), map(), term()) :: {:ok, map()} | {:error, term()}
  def execute(module, params, context) do
    with {:ok, validated} <- validate(module, params) do
      module.run(validated, context)
    end
  end

  @doc "Action을 그래프 노드로 변환한다. MFA를 반환한다 (durable 그래프 호환)."
  @spec to_node(module()) :: {module(), atom(), [term()]}
  def to_node(module), do: {__MODULE__, :run_as_node, [module]}

  @doc false
  def run_as_node(state, ctx, module) do
    params =
      state
      |> Map.take(Keyword.keys(module.schema()))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case execute(module, params, ctx) do
      {:ok, update} -> update
      {:error, reason} -> raise ElGraph.ActionError, action: module, reason: reason
    end
  end

  @doc "스키마에서 LLM tool-calling 스펙을 생성한다. `input_schema`는 JSON Schema 맵."
  @spec to_tool_spec(module()) :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }
  def to_tool_spec(module) do
    schema = module.schema()

    properties =
      Map.new(schema, fn {key, spec} -> {Atom.to_string(key), property_schema(spec)} end)

    required = for {key, spec} <- schema, spec[:required] == true, do: Atom.to_string(key)

    %{
      name: module.name(),
      description: module.description(),
      input_schema: %{"type" => "object", "properties" => properties, "required" => required}
    }
  end

  ## 내부

  # LLM tool-call JSON은 문자열 키로 오므로 스키마에 선언된 키만 atom으로 변환한다.
  defp params_to_keyword(module, params) do
    known = Keyword.keys(module.schema())

    Enum.reduce_while(params, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key, known) do
        {:ok, atom_key} -> {:cont, {:ok, [{atom_key, value} | acc]}}
        :error -> {:halt, {:error, {:unknown_param, key}}}
      end
    end)
  end

  defp normalize_key(key, _known) when is_atom(key), do: {:ok, key}

  defp normalize_key(key, known) when is_binary(key) do
    Enum.find_value(known, :error, fn atom_key ->
      if Atom.to_string(atom_key) == key, do: {:ok, atom_key}
    end)
  end

  defp property_schema(spec) do
    base = type_schema(Keyword.get(spec, :type, :any))

    case spec[:doc] do
      nil -> base
      doc -> Map.put(base, "description", doc)
    end
  end

  defp type_schema(:string), do: %{"type" => "string"}
  defp type_schema(:boolean), do: %{"type" => "boolean"}
  defp type_schema(:integer), do: %{"type" => "integer"}
  defp type_schema(:pos_integer), do: %{"type" => "integer"}
  defp type_schema(:non_neg_integer), do: %{"type" => "integer"}
  defp type_schema(:float), do: %{"type" => "number"}
  defp type_schema(:atom), do: %{"type" => "string"}
  defp type_schema(:map), do: %{"type" => "object"}
  defp type_schema({:list, inner}), do: %{"type" => "array", "items" => type_schema(inner)}
  defp type_schema({:in, choices}), do: %{"enum" => Enum.map(choices, &to_json_value/1)}
  defp type_schema(_other), do: %{}

  defp to_json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_json_value(value), do: value
end
