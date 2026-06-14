defmodule ElGraph.MCP.Tool do
  @moduledoc """
  MCP 서버에서 가져온 툴 (SPEC §4: MCP 툴 → Action 자동 변환).

  `to_tool_spec/1`은 `ElGraph.Action.to_tool_spec/1`과 같은 형태를 반환하므로
  LLM tool-calling 루프에서 Action과 MCP 툴을 구분 없이 섞어 쓸 수 있다.
  """

  defstruct [:name, :description, :input_schema, :client_mod, :client]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          client_mod: module(),
          client: ElGraph.MCP.Client.client()
        }

  @doc false
  def from_def(tool_def, client_mod, client) do
    %__MODULE__{
      name: field(tool_def, "name", :name),
      description: field(tool_def, "description", :description),
      input_schema: field(tool_def, "inputSchema", :input_schema) || %{},
      client_mod: client_mod,
      client: client
    }
  end

  @doc "Action과 동일한 형태의 LLM tool 스펙을 반환한다."
  @spec to_tool_spec(t()) :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map()
        }
  def to_tool_spec(%__MODULE__{} = tool) do
    %{name: tool.name, description: tool.description, input_schema: tool.input_schema}
  end

  @doc "클라이언트를 통해 MCP 서버의 툴을 호출한다."
  @spec execute(t(), map(), term()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = tool, params, _ctx) do
    tool.client_mod.call_tool(tool.client, tool.name, params)
  end

  defp field(tool_def, string_key, atom_key) do
    Map.get(tool_def, string_key) || Map.get(tool_def, atom_key)
  end
end
