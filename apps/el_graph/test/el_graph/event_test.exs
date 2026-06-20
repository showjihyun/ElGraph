defmodule ElGraph.EventTest do
  use ExUnit.Case, async: true

  alias ElGraph.{AGUI, Ctx, Event}

  # 토큰을 emit하고 끝나는 노드 — 실제 스트림이 노드/종료 봉투를 모두 내도록.
  def emit_node(_state, ctx) do
    Ctx.emit(ctx, {:token, "hi"})
    %{}
  end

  defp graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:a, &__MODULE__.emit_node/2)
    |> ElGraph.compile(entry: :a)
  end

  describe "builders" do
    test "node/4 carries thread_id/step/node/event" do
      assert %{thread_id: "t", step: 1, node: :a, event: {:token, "x"}} =
               Event.node("t", 1, :a, {:token, "x"})
    end

    test "done/2 and down/2 carry thread_id + a terminal event, no step/node" do
      assert %{thread_id: "t", event: {:done, {:ok, %{}}}} = Event.done("t", {:ok, %{}})
      assert %{thread_id: "t", event: {:down, :killed}} = Event.down("t", :killed)
      refute Map.has_key?(Event.done("t", :r), :step)
    end
  end

  # 계약: 실제 ElGraph.stream이 내는 봉투가 선언된 형태를 지키는지 — 생산자(emit/실행기/Runner)가
  # 드리프트하면 여기서 깨진다. 소비자(AGUI)는 이 형태에 의존한다.
  describe "stream envelope contract" do
    test "every stream element conforms to the declared envelope" do
      events = graph() |> ElGraph.stream(%{}) |> Enum.to_list()

      # 모든 원소는 thread_id + event를 가진다.
      assert Enum.all?(events, &match?(%{thread_id: _, event: _}, &1))

      # 노드 봉투: step·node 포함 (생명주기 + 토큰).
      assert Enum.any?(
               events,
               &match?(%{thread_id: _, step: _, node: :a, event: :node_start}, &1)
             )

      assert Enum.any?(
               events,
               &match?(%{thread_id: _, step: _, node: :a, event: {:token, "hi"}}, &1)
             )

      # 종료 봉투: thread_id + {:done, _}, step·node 없음.
      assert %{thread_id: _, event: {:done, {:ok, %{}}}} = last = List.last(events)
      refute Map.has_key?(last, :step)
    end

    test "the stream feeds AGUI.transform end-to-end" do
      agui = graph() |> ElGraph.stream(%{}) |> AGUI.transform("t", "r") |> Enum.to_list()

      assert [%{"type" => "RUN_STARTED"} | _] = agui
      assert Enum.any?(agui, &match?(%{"type" => "TEXT_MESSAGE_CONTENT", "delta" => "hi"}, &1))
      assert List.last(agui)["type"] == "RUN_FINISHED"
    end
  end
end
