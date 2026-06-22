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

defmodule ElGraph.DurabilityTest.CapturingCheckpointer do
  @moduledoc false
  # put/put_writes 호출을 config의 test pid로 흘려 보내는 체크포인터 — Durability 모듈의
  # 모드 디스패치를 격리 검증한다(어떤 모드가 실제로 기록/생략하는지).
  @behaviour ElGraph.Checkpointer

  @impl true
  def put(pid, checkpoint), do: send(pid, {:put, checkpoint}) && :ok
  @impl true
  def get(_pid, _thread_id, _step), do: :not_found
  @impl true
  def put_writes(pid, thread_id, step, writes),
    do: send(pid, {:put_writes, thread_id, step, writes}) && :ok

  @impl true
  def get_writes(_pid, _thread_id, _step), do: []
  @impl true
  def list(_pid, _thread_id), do: []
end

defmodule ElGraph.DurabilityTest.MisbehavingCheckpointer do
  @moduledoc false
  # 쓰기가 exit/throw하거나 계약 밖 값(:ok|{:error} 외)을 반환하는 체크포인터 — config가
  # 동작을 고른다. Durability.run_write의 catch :exit / catch :throw / 비계약 반환 격리 검증용.
  @behaviour ElGraph.Checkpointer

  @impl true
  def put(action, _checkpoint), do: act(action)
  @impl true
  def get(_action, _thread_id, _step), do: :not_found
  @impl true
  def put_writes(action, _thread_id, _step, _writes), do: act(action)
  @impl true
  def get_writes(_action, _thread_id, _step), do: []
  @impl true
  def list(_action, _thread_id), do: []

  defp act(:exit), do: exit(:boom)
  defp act(:throw), do: throw(:nope)
  defp act(:weird), do: :weird
end

defmodule ElGraph.DurabilityTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpointer.ETS
  alias ElGraph.Durability

  alias ElGraph.DurabilityTest.{
    CapturingCheckpointer,
    FailingCheckpointer,
    MisbehavingCheckpointer,
    RaisingCheckpointer
  }

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

  # Durability seam을 격리 검증한다 — 실행기 없이 모드 디스패치/지연 빌드/none 흡수만.
  describe "Durability 모듈 (직접)" do
    defp handle(mode),
      do: Durability.new(checkpointer: {CapturingCheckpointer, self()}, durability: mode)

    defp tracked_checkpoint(tag) do
      send(self(), {:built, tag})
      %Checkpoint{thread_id: "t", step: 1, state: %{}, next: []}
    end

    test "new/1 folds a missing checkpointer into :none and still validates the mode" do
      assert %Durability{mode: :none, checkpointer: nil} = Durability.new([])

      assert %Durability{mode: :sync} =
               Durability.new(checkpointer: {CapturingCheckpointer, self()})

      assert_raise ArgumentError, ~r/durability/, fn ->
        Durability.new(checkpointer: {CapturingCheckpointer, self()}, durability: :bogus)
      end
    end

    test ":sync on_step builds and writes the checkpoint" do
      assert :ok = Durability.on_step(handle(:sync), fn -> tracked_checkpoint(:s) end)
      assert_received {:built, :s}
      assert_received {:put, %Checkpoint{step: 1}}
    end

    test ":exit on_step skips — the checkpoint thunk is never even built" do
      assert :ok = Durability.on_step(handle(:exit), fn -> tracked_checkpoint(:e) end)
      refute_received {:built, :e}
      refute_received {:put, _}
    end

    test ":none on_step is a no-op without a checkpointer" do
      assert :ok = Durability.on_step(Durability.new([]), fn -> tracked_checkpoint(:n) end)
      refute_received {:built, :n}
    end

    test "on_finalize writes only for :exit; on_interrupt likewise" do
      assert :ok = Durability.on_finalize(handle(:exit), fn -> tracked_checkpoint(:f) end)
      assert_received {:put, %Checkpoint{}}

      assert :ok = Durability.on_finalize(handle(:sync), fn -> tracked_checkpoint(:f2) end)
      refute_received {:built, :f2}
    end

    test "put_now writes regardless of mode" do
      assert :ok = Durability.put_now(handle(:exit), %Checkpoint{thread_id: "t", step: 2})
      assert_received {:put, %Checkpoint{step: 2}}
    end

    test ":async session enqueues to a writer and flush drains it before return" do
      cp = %Checkpoint{thread_id: "t", step: 3, state: %{}, next: []}

      Durability.with_session(handle(:async), fn d ->
        assert :ok = Durability.on_step(d, fn -> cp end)
        assert :ok = Durability.flush(d)
        # flush 반환 시점엔 writer가 이미 기록했어야 한다.
        assert_received {:put, %Checkpoint{step: 3}}
      end)
    end

    test ":async on_writes enqueues put_writes and flush drains it before return" do
      Durability.with_session(handle(:async), fn d ->
        assert :ok = Durability.on_writes(d, "t", 5, [{:a, %{x: 1}}])
        assert :ok = Durability.flush(d)
        assert_received {:put_writes, "t", 5, [{:a, %{x: 1}}]}
      end)
    end

    test "isolates an exiting adapter write as {:error, {:exit, _}} + telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :checkpoint, :error]])
      d = Durability.new(checkpointer: {MisbehavingCheckpointer, :exit})

      assert {:error, {:exit, :boom}} =
               Durability.put_now(d, %Checkpoint{thread_id: "t", step: 1})

      assert_receive {[:el_graph, :checkpoint, :error], ^ref, %{},
                      %{thread_id: "t", step: 1, reason: {:exit, :boom}}}
    end

    test "isolates a throwing adapter write as {:error, {:throw, _}}" do
      d = Durability.new(checkpointer: {MisbehavingCheckpointer, :throw})

      assert {:error, {:throw, :nope}} =
               Durability.put_now(d, %Checkpoint{thread_id: "t", step: 1})
    end

    test "surfaces a non-contract return as {:error, {:invalid_checkpointer_return, _}}" do
      d = Durability.new(checkpointer: {MisbehavingCheckpointer, :weird})

      assert {:error, {:invalid_checkpointer_return, :weird}} =
               Durability.put_now(d, %Checkpoint{thread_id: "t", step: 1})
    end
  end
end
