defmodule ElGraph.DurabilityTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.ETS
  alias ElGraph.{Checkpoint, TestNodes}

  # a → b → c : superstep마다 체크포인트가 찍히는 선형 그래프 (sync면 step 0..3 = 4개).
  defp linear_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:a, &TestNodes.noop/2)
    |> ElGraph.add_node(:b, &TestNodes.noop/2)
    |> ElGraph.add_node(:c, &TestNodes.noop/2)
    |> ElGraph.add_edge(:a, :b)
    |> ElGraph.add_edge(:b, :c)
    |> ElGraph.compile(entry: :a)
  end

  defp ask_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:ask, &TestNodes.ask/2)
    |> ElGraph.compile(entry: :ask)
  end

  setup do
    pid = start_supervised!(ETS)
    %{cp: {ETS, ETS.config(pid)}, config: ETS.config(pid)}
  end

  describe ":sync (기본)" do
    test "superstep마다 체크포인트를 영속한다 (step 0..3)", %{cp: cp, config: config} do
      assert {:ok, _} = ElGraph.invoke(linear_graph(), %{}, checkpointer: cp, thread_id: "t")
      assert length(ETS.list(config, "t")) == 4
    end
  end

  describe ":exit" do
    test "최종 체크포인트만 영속한다 (중간 step 없음)", %{cp: cp, config: config} do
      assert {:ok, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: cp,
                 thread_id: "t",
                 durability: :exit
               )

      assert [%{step: 3}] = ETS.list(config, "t")
      assert {:ok, %Checkpoint{next: []}} = ETS.get(config, "t", :latest)
    end

    test "동적 인터럽트는 그래도 영속돼 재개 가능하다", %{cp: cp, config: config} do
      assert {:interrupted, _} =
               ElGraph.invoke(ask_graph(), %{},
                 checkpointer: cp,
                 thread_id: "t",
                 durability: :exit
               )

      assert {:ok, %Checkpoint{interrupted: :ask}} = ETS.get(config, "t", :latest)

      assert {:ok, %{result: "Bob"}} =
               ElGraph.resume(ask_graph(),
                 checkpointer: cp,
                 thread_id: "t",
                 resume: "Bob",
                 durability: :exit
               )
    end

    test "정적 인터럽트(interrupt_before)도 영속돼 재개 가능하다", %{cp: cp, config: config} do
      assert {:interrupted, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: cp,
                 thread_id: "t",
                 interrupt_before: [:b],
                 durability: :exit
               )

      assert {:ok, %Checkpoint{next: [{:b, :b, nil}]}} = ETS.get(config, "t", :latest)
    end
  end

  describe ":async" do
    test "반환 전 flush되어 모든 체크포인트가 영속된다", %{cp: cp, config: config} do
      assert {:ok, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: cp,
                 thread_id: "t",
                 durability: :async
               )

      assert length(ETS.list(config, "t")) == 4
    end

    test "인터럽트가 내구적으로 영속돼 재개 가능하다", %{cp: cp, config: config} do
      assert {:interrupted, _} =
               ElGraph.invoke(ask_graph(), %{},
                 checkpointer: cp,
                 thread_id: "t",
                 durability: :async
               )

      assert {:ok, %Checkpoint{interrupted: :ask}} = ETS.get(config, "t", :latest)

      assert {:ok, %{result: "Bob"}} =
               ElGraph.resume(ask_graph(), checkpointer: cp, thread_id: "t", resume: "Bob")
    end
  end

  describe "검증" do
    test "알 수 없는 durability 모드는 거부한다", %{cp: cp} do
      assert_raise ArgumentError, fn ->
        ElGraph.invoke(linear_graph(), %{}, checkpointer: cp, thread_id: "t", durability: :bogus)
      end
    end
  end
end
