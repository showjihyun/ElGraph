defmodule ElGraph.A2A do
  @moduledoc """
  A2A(Agent2Agent) 프로토콜 매핑 (SPEC §6, 부록 A2A 표).

  조직 경계 밖 에이전트와의 상호운용을 위한 순수 변환 계층이다. ElGraph 실행 결과를
  A2A Task 상태로, Skill 설정을 Agent Card로 변환한다. HTTP 서버(JSON-RPC 바인딩, SSE)는
  이 매핑 위의 얇은 계층으로 별도 앱 `el_graph_web`(Plug/Bandit)가 담당한다.

  Task 상태 매핑 (M1 프리미티브 ↔ A2A):
    `{:ok, _}`          → COMPLETED
    `{:error, _}`       → FAILED
    `{:interrupted, _}` → INPUT_REQUIRED (HITL — resume이 입력 제공)
    실행 중             → WORKING
  """

  alias ElGraph.Checkpoint

  @doc """
  ElGraph 실행 결과를 A2A Task 상태(맵)로 변환한다.

      iex> ElGraph.A2A.to_task_state({:ok, %{answer: 42}}).state
      "completed"

      iex> ElGraph.A2A.to_task_state({:error, :boom}).state
      "failed"
  """
  @spec to_task_state(tuple()) :: map()
  def to_task_state({:ok, state}), do: %{state: "completed", result: state}
  def to_task_state({:error, reason}), do: %{state: "failed", error: reason}

  def to_task_state({:interrupted, %{payload: payload}}),
    do: %{state: "input-required", payload: payload}

  @doc """
  체크포인터에 영속된 durable run을 A2A Task로 변환한다 (thread_id로 조회).

  최신 체크포인트에서 상태를 도출한다 — 어떤 체크포인터 백엔드(ETS/DETS/Mnesia/Postgres/Redis)든
  무관하다(behaviour만 사용). A2A Task 생명주기 ↔ 체크포인트:

    * `next == []`          → COMPLETED (결과 = 최종 state)
    * 동적 인터럽트 대기      → INPUT_REQUIRED (payload 포함 — resume이 입력 제공)
    * 진행 중(미완·미인터럽트) → WORKING
    * 미존재                 → SUBMITTED

  `to_task_state/1`을 재사용해 결과/페이로드 표현을 일관되게 유지한다. 정적 `interrupt_before`는
  체크포인트에 인터럽트 표식을 남기지 않으므로 WORKING으로 보인다(동적 인터럽트가 HITL의 기본 경로).
  """
  @spec task_from_checkpoint({module(), term()}, String.t()) :: map()
  def task_from_checkpoint({mod, config}, thread_id) do
    %{id: thread_id, status: checkpoint_status(mod.get(config, thread_id, :latest))}
  end

  defp checkpoint_status({:ok, %Checkpoint{next: []} = checkpoint}),
    do: to_task_state({:ok, checkpoint.state})

  defp checkpoint_status({:ok, %Checkpoint{interrupted: node, interrupt_info: info}})
       when not is_nil(node),
       do: to_task_state({:interrupted, %{node: node, payload: info && info.payload}})

  defp checkpoint_status({:ok, %Checkpoint{}}), do: %{state: "working"}
  defp checkpoint_status(:not_found), do: %{state: "submitted"}

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

  @doc """
  A2A Message(JSON)에서 ElGraph 시그널 입력을 추출한다 (text part들을 이어붙임).

      iex> ElGraph.A2A.message_to_input(%{"parts" => [%{"text" => "엘릭서"}, %{"text" => " 검색"}]})
      %{question: "엘릭서 검색"}
  """
  @spec message_to_input(map()) :: %{question: String.t()}
  def message_to_input(%{"parts" => parts}) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
      |> Enum.map_join("", & &1["text"])

    %{question: text}
  end

  # parts가 없거나 형태가 어긋난 메시지는 빈 질문으로 — HTTP 바인딩이 500으로 죽지 않게(graceful).
  def message_to_input(_message), do: %{question: ""}
end
