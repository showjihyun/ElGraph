defmodule ElGraph.DurabilityTest.FailingCheckpointer do
  @moduledoc false
  # 모든 쓰기가 실패하는 체크포인터 — :async writer의 오류 처리 검증용.
  @behaviour ElGraph.Checkpointer

  @impl true
  def put(_config, _checkpoint), do: {:error, :disk_full}
  @impl true
  def get(_config, _thread_id, _step), do: :not_found
  @impl true
  def put_writes(_config, _thread_id, _step, _writes), do: {:error, :disk_full}
  @impl true
  def get_writes(_config, _thread_id, _step), do: []
  @impl true
  def list(_config, _thread_id), do: []
end

defmodule ElGraph.DurabilityTest.RaisingCheckpointer do
  @moduledoc false
  # 쓰기가 예외를 raise하는 체크포인터 — 프로덕션 어댑터(Postgres SQL.query!, Redis
  # `{:ok,_}=Redix...`)는 I/O 오류 시 {:error}를 반환하지 않고 raise한다. :async writer가
  # 이를 격리하지 못하면 spawn_link로 executor(동기 invoke면 호출자)까지 죽는다.
  @behaviour ElGraph.Checkpointer

  @impl true
  def put(_config, _checkpoint), do: raise("write boom")
  @impl true
  def get(_config, _thread_id, _step), do: :not_found
  @impl true
  def put_writes(_config, _thread_id, _step, _writes), do: raise("write boom")
  @impl true
  def get_writes(_config, _thread_id, _step), do: []
  @impl true
  def list(_config, _thread_id), do: []
end

defmodule ElGraph.DurabilityTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.ETS
  alias ElGraph.DurabilityTest.{FailingCheckpointer, RaisingCheckpointer}
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

    test "쓰기 실패를 조용히 삼키지 않고 telemetry로 알린다" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])

      assert {:ok, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: {FailingCheckpointer, :cfg},
                 thread_id: "t",
                 durability: :async
               )

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", reason: :disk_full}}
    end

    test "raise하는 어댑터에도 writer가 죽지 않고 telemetry로 알린 뒤 실행을 끝낸다" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])

      # 프로덕션 어댑터처럼 put이 raise해도, spawn_link된 writer가 죽으며 (동기 invoke의)
      # 호출 프로세스까지 끌고 죽으면 안 된다 — 격리해 telemetry로 변환하고 실행은 완료된다.
      assert {:ok, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: {RaisingCheckpointer, :cfg},
                 thread_id: "t",
                 durability: :async
               )

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", reason: %RuntimeError{message: "write boom"}}}
    end
  end

  describe "raise하는 어댑터 격리 (전 모드, executor 프로세스 쓰기)" do
    test ":sync는 raise를 호출자 크래시가 아니라 {:error}로 surface한다 + telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])

      # 기본(:sync) 경로의 do_put은 executor 프로세스에서 mod.put을 직접 호출한다 —
      # raise하면 (동기 invoke의) 호출자까지 죽으면 안 되고, 강한 보장 모드이므로 실행을 실패시킨다.
      assert {:error, %RuntimeError{message: "write boom"}} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: {RaisingCheckpointer, :cfg},
                 thread_id: "t"
               )

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", reason: %RuntimeError{message: "write boom"}}}
    end

    test ":exit 최종 쓰기가 raise해도 호출자를 죽이지 않고 telemetry로 알린다" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])

      # :exit는 finalize의 do_put이 유일한 영속 지점 — 속도 모드라 실패는 telemetry로만 알리고
      # 실행은 완료된다(크래시 금지).
      assert {:ok, _} =
               ElGraph.invoke(linear_graph(), %{},
                 checkpointer: {RaisingCheckpointer, :cfg},
                 thread_id: "t",
                 durability: :exit
               )

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", reason: %RuntimeError{message: "write boom"}}}
    end

    test "동적 인터럽트 체크포인트 쓰기가 raise해도 호출자를 죽이지 않고 {:error}로 알린다" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])

      # :exit라 step 0 저장은 생략되고, 인터럽트 시점의 동기 mod.put(dynamic_interrupt)이 raise한다.
      assert {:error, %RuntimeError{message: "write boom"}} =
               ElGraph.invoke(ask_graph(), %{},
                 checkpointer: {RaisingCheckpointer, :cfg},
                 thread_id: "t",
                 durability: :exit
               )

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", reason: %RuntimeError{message: "write boom"}}}
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
