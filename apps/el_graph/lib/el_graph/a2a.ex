defmodule ElGraph.A2A do
  @moduledoc """
  A2A(Agent2Agent) 프로토콜 매핑 (SPEC §6, 부록 A2A 표).

  조직 경계 밖 에이전트와의 상호운용을 위한 순수 변환 계층이다. ElGraph 실행 결과를
  A2A Task 상태로, Skill 설정을 Agent Card로 변환한다. HTTP 서버(REST/JSON-RPC 바인딩,
  SSE)는 이 매핑 위의 얇은 계층으로 별도 패키지(`el_graph_a2a`)가 담당한다.

  Task 상태 매핑 (M1 프리미티브 ↔ A2A):
    `{:ok, _}`          → COMPLETED
    `{:error, _}`       → FAILED
    `{:interrupted, _}` → INPUT_REQUIRED (HITL — resume이 입력 제공)
    실행 중             → WORKING
  """

  @doc "ElGraph 실행 결과를 A2A Task 상태(맵)로 변환한다."
  @spec to_task_state(tuple()) :: map()
  def to_task_state({:ok, state}), do: %{state: "completed", result: state}
  def to_task_state({:error, reason}), do: %{state: "failed", error: reason}

  def to_task_state({:interrupted, %{payload: payload}}),
    do: %{state: "input-required", payload: payload}

  @doc """
  에이전트 설정을 A2A Agent Card(JSON 직렬화 가능 맵)로 변환한다.

  `:tools`(Action 모듈)의 tool 스펙을 A2A skills로 노출한다.
  """
  @spec agent_card(keyword()) :: map()
  def agent_card(opts) do
    skills =
      opts
      |> Keyword.get(:tools, [])
      |> Enum.map(fn action ->
        spec = action.to_tool_spec()

        %{
          "id" => spec.name,
          "description" => spec.description,
          "inputSchema" => spec.input_schema
        }
      end)

    %{
      "name" => Keyword.fetch!(opts, :name),
      "description" => Keyword.fetch!(opts, :description),
      "capabilities" => %{"streaming" => true, "pushNotifications" => false},
      "skills" => skills
    }
  end

  @doc "A2A Message(JSON)에서 ElGraph 시그널 입력을 추출한다 (text part들을 이어붙임)."
  @spec message_to_input(map()) :: %{question: String.t()}
  def message_to_input(%{"parts" => parts}) do
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map_join("", & &1["text"])

    %{question: text}
  end
end
