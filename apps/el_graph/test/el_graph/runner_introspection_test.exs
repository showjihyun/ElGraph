defmodule ElGraph.RunnerIntrospectionTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Runner, TestNodes}

  @registry __MODULE__.Registry

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  defp slow_graph(sleep_ms) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:work, {TestNodes, :slow, [sleep_ms]})
    |> ElGraph.compile(entry: :work)
  end

  # Registry 등록/정리는 다른 프로세스에서 비동기로 일어나므로 짧게 폴링한다.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          10 -> :ok
        end

        eventually(fun, attempts - 1)
    end
  end

  describe "introspection (SPEC §3.4, 부록 A-1)" do
    test "a running thread is listed with live progress and cleaned up on exit" do
      {:ok, run} =
        Runner.start_run(slow_graph(300), %{}, registry: @registry, thread_id: "t1")

      assert eventually(fn ->
               match?({:ok, %{step: 0, active: [:work]}}, Runner.peek(@registry, "t1"))
             end)

      assert [%{thread_id: "t1", step: 0, active: [:work], pid: pid}] = Runner.list(@registry)
      assert is_pid(pid)

      assert {:ok, _state} = Runner.await(run, 2_000)

      # 실행 프로세스가 죽으면 Registry가 자동 정리한다.
      assert eventually(fn -> Runner.peek(@registry, "t1") == :not_found end)
      assert eventually(fn -> Runner.list(@registry) == [] end)
    end

    test "peek of an unknown thread is :not_found" do
      assert :not_found = Runner.peek(@registry, "ghost")
    end

    test "runs without a :registry option are not tracked" do
      {:ok, run} = Runner.start_run(slow_graph(5), %{}, thread_id: "t2")

      assert :not_found = Runner.peek(@registry, "t2")
      assert {:ok, _state} = Runner.await(run, 2_000)
    end
  end
end
