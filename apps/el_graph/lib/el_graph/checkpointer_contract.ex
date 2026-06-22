defmodule ElGraph.CheckpointerContract do
  @moduledoc """
  모든 체크포인터 어댑터가 통과해야 하는 공유 계약 테스트 (SPEC §3.5, TDD-SPEC §4).

  사용하는 테스트 모듈은 `setup`에서 `%{mod: 어댑터모듈, config: 어댑터설정}`을 제공해야 한다.

  별도 앱의 어댑터(`el_graph_ecto`, `el_graph_redis` 등)도 `use ElGraph.CheckpointerContract`
  한 줄로 동일 계약을 검증한다. 테스트 전용 매크로지만 다운스트림 어댑터가 재사용해야 하므로
  `lib/`에 둔다(컴파일 비용 0 — `__using__` 매크로 정의일 뿐).
  """

  defmacro __using__(_opts) do
    quote do
      alias ElGraph.Checkpoint

      defp contract_cp(thread_id, step, state, next \\ []) do
        %Checkpoint{thread_id: thread_id, step: step, state: state, next: next}
      end

      describe "checkpointer contract: checkpoints" do
        test "put then get :latest returns the checkpoint", %{mod: mod, config: config} do
          checkpoint = contract_cp("t1", 0, %{x: 1}, [:a])

          assert :ok = mod.put(config, checkpoint)
          assert {:ok, ^checkpoint} = mod.get(config, "t1", :latest)
        end

        test "get by step returns that specific checkpoint", %{mod: mod, config: config} do
          :ok = mod.put(config, contract_cp("t1", 0, %{x: 0}))
          :ok = mod.put(config, contract_cp("t1", 1, %{x: 1}))

          assert {:ok, %Checkpoint{step: 0, state: %{x: 0}}} = mod.get(config, "t1", 0)
        end

        test ":latest returns the highest step", %{mod: mod, config: config} do
          for step <- 0..2, do: :ok = mod.put(config, contract_cp("t1", step, %{x: step}))

          assert {:ok, %Checkpoint{step: 2, state: %{x: 2}}} = mod.get(config, "t1", :latest)
        end

        test "threads are isolated", %{mod: mod, config: config} do
          :ok = mod.put(config, contract_cp("t1", 0, %{x: :one}))
          :ok = mod.put(config, contract_cp("t2", 0, %{x: :two}))

          assert {:ok, %Checkpoint{state: %{x: :one}}} = mod.get(config, "t1", :latest)
          assert {:ok, %Checkpoint{state: %{x: :two}}} = mod.get(config, "t2", :latest)
        end

        test "unknown thread is :not_found", %{mod: mod, config: config} do
          assert :not_found = mod.get(config, "ghost", :latest)
          assert :not_found = mod.get(config, "ghost", 0)
        end

        test "checkpoints carry schema version 1", %{mod: mod, config: config} do
          :ok = mod.put(config, contract_cp("t1", 0, %{}))

          assert {:ok, %Checkpoint{version: 1}} = mod.get(config, "t1", :latest)
        end

        test "state containing a pid is rejected as not serializable", %{mod: mod, config: config} do
          assert {:error, {:not_serializable, _value}} =
                   mod.put(config, contract_cp("t1", 0, %{x: self()}))

          assert :not_found = mod.get(config, "t1", :latest)
        end

        test "a non-serializable value outside :state (e.g. task_cache) is rejected",
             %{mod: mod, config: config} do
          # 체크포인트는 통째로 직렬화되므로 :state 밖(task_cache/interrupt_info 등)의 pid도
          # 거부돼야 한다 — 그러지 않으면 영속 후 재개 시 죽은 pid로 복원돼 무결성이 깨진다.
          checkpoint = %Checkpoint{
            thread_id: "t1",
            step: 0,
            state: %{},
            next: [],
            task_cache: %{{:node, 1} => self()}
          }

          assert {:error, {:not_serializable, _value}} = mod.put(config, checkpoint)
          assert :not_found = mod.get(config, "t1", :latest)
        end

        test "list returns checkpoint metadata in step order", %{mod: mod, config: config} do
          for step <- 0..2, do: :ok = mod.put(config, contract_cp("t1", step, %{}))
          :ok = mod.put(config, contract_cp("other", 9, %{}))

          assert [%{step: 0, version: 1}, %{step: 1, version: 1}, %{step: 2, version: 1}] =
                   mod.list(config, "t1")

          assert [] = mod.list(config, "ghost")
        end
      end

      describe "checkpointer contract: pending writes" do
        test "put_writes then get_writes roundtrip in order", %{mod: mod, config: config} do
          writes = [{:a, %{x: 1}}, {:b, %{y: 2}}]

          assert :ok = mod.put_writes(config, "t1", 3, writes)
          assert ^writes = mod.get_writes(config, "t1", 3)
        end

        test "get_writes without stored writes returns []", %{mod: mod, config: config} do
          assert [] = mod.get_writes(config, "t1", 0)
        end

        test "writes are isolated per thread and step", %{mod: mod, config: config} do
          :ok = mod.put_writes(config, "t1", 1, [{:a, %{x: 1}}])
          :ok = mod.put_writes(config, "t2", 1, [{:a, %{x: 2}}])

          assert [{:a, %{x: 1}}] = mod.get_writes(config, "t1", 1)
          assert [{:a, %{x: 2}}] = mod.get_writes(config, "t2", 1)
          assert [] = mod.get_writes(config, "t1", 2)
        end

        test "writes containing a pid are rejected", %{mod: mod, config: config} do
          assert {:error, {:not_serializable, _value}} =
                   mod.put_writes(config, "t1", 0, [{:a, %{x: self()}}])
        end
      end
    end
  end
end
