defmodule ElGraph.RetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.{CompileError, TestNodes}

  defp fail_graph(node_opts, table, fail_n) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:work, {TestNodes, :fail_times, [table, fail_n]}, node_opts)
    |> ElGraph.compile(entry: :work)
  end

  defp counter_table, do: :ets.new(:retry_counter, [:public])

  describe "retry policy (SPEC §4)" do
    test "retries a crashing node and succeeds within max" do
      table = counter_table()
      graph = fail_graph([retry: [max: 2, backoff: :none]], table, 2)

      assert {:ok, %{result: {:ok_after, 3}}} = ElGraph.invoke(graph, %{})
    end

    test "returns the last error when retries are exhausted" do
      table = counter_table()
      graph = fail_graph([retry: [max: 1, backoff: :none]], table, 5)

      assert {:error, {:node_crashed, :work, %RuntimeError{message: "fail 2"}}} =
               ElGraph.invoke(graph, %{})

      assert [{:calls, 2}] = :ets.lookup(table, :calls)
    end

    test "does not retry by default" do
      table = counter_table()
      graph = fail_graph([], table, 1)

      assert {:error, {:node_crashed, :work, _exception}} = ElGraph.invoke(graph, %{})
      assert [{:calls, 1}] = :ets.lookup(table, :calls)
    end

    test "exponential backoff path retries and succeeds" do
      table = counter_table()
      graph = fail_graph([retry: [max: 2, backoff: :exponential, base: 1]], table, 2)

      assert {:ok, %{result: {:ok_after, 3}}} = ElGraph.invoke(graph, %{})
    end

    test "timeouts are retried" do
      table = counter_table()

      graph =
        ElGraph.new()
        |> ElGraph.state(:messages, default: [], reducer: {ElGraph.Reducers, :append, []})
        |> ElGraph.add_node(:work, {TestNodes, :slow_once, [table, 500]},
          timeout: 50,
          retry: [max: 1, backoff: :none]
        )
        |> ElGraph.compile(entry: :work)

      assert {:ok, %{messages: ["b"]}} = ElGraph.invoke(graph, %{})
    end

    test "retry_on restricts retries to matching exception modules" do
      table = counter_table()
      graph = fail_graph([retry: [max: 3, backoff: :none, retry_on: [ArgumentError]]], table, 1)

      # RuntimeError는 retry_on 목록에 없으므로 재시도하지 않는다.
      assert {:error, {:node_crashed, :work, %RuntimeError{}}} = ElGraph.invoke(graph, %{})
      assert [{:calls, 1}] = :ets.lookup(table, :calls)
    end

    test "retry options are validated at compile time" do
      assert_raise CompileError, ~r/:retry/, fn ->
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:work, &TestNodes.noop/2, retry: [max: -1])
        |> ElGraph.compile(entry: :work)
      end

      assert_raise CompileError, ~r/:retry/, fn ->
        ElGraph.new()
        |> ElGraph.state(:result)
        |> ElGraph.add_node(:work, &TestNodes.noop/2, retry: [max: 1, backoff: :bogus])
        |> ElGraph.compile(entry: :work)
      end
    end
  end
end
