defmodule ElGraph.RunnerTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Reducers, Runner, TestNodes}

  defp sequential_graph do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:greet, &TestNodes.greet/2)
    |> ElGraph.add_node(:shout, &TestNodes.shout/2)
    |> ElGraph.add_edge(:greet, :shout)
    |> ElGraph.compile(entry: :greet)
  end

  defp single_node_graph(node_fun) do
    ElGraph.new()
    |> ElGraph.state(:result)
    |> ElGraph.add_node(:work, node_fun)
    |> ElGraph.compile(entry: :work)
  end

  describe "stream/3 (SPEC §3.7)" do
    test "yields lifecycle events in order, ending with the result" do
      events = sequential_graph() |> ElGraph.stream(%{}) |> Enum.to_list()

      assert [
               %{event: :node_start, node: :greet, step: 0},
               %{event: :node_end, node: :greet, step: 0},
               %{event: :node_start, node: :shout, step: 1},
               %{event: :node_end, node: :shout, step: 1},
               %{event: {:done, {:ok, %{result: "HELLO"}}}}
             ] = events
    end

    test "includes custom Ctx.emit events between lifecycle events" do
      graph = single_node_graph(&TestNodes.emit_token/2)

      events = graph |> ElGraph.stream(%{}) |> Enum.to_list()

      assert [
               %{event: :node_start, node: :work},
               %{event: {:token, "hi"}, node: :work},
               %{event: :node_end, node: :work},
               %{event: {:done, {:ok, _state}}}
             ] = events
    end

    test "halting the stream early cleans up the runner without leaking links" do
      {:links, links_before} = Process.info(self(), :links)

      looping_graph =
        ElGraph.new()
        |> ElGraph.state(:count, default: 0, reducer: {Reducers, :add, []})
        |> ElGraph.add_node(:inc, &TestNodes.inc/2)
        |> ElGraph.add_edge(:inc, :inc)
        |> ElGraph.compile(entry: :inc)

      events =
        looping_graph
        |> ElGraph.stream(%{}, max_steps: 1_000)
        |> Enum.take(4)

      assert [%{event: :node_start}, %{event: :node_end} | _rest] = events
      assert {:links, ^links_before} = Process.info(self(), :links)
    end
  end

  describe "start_run/await (SPEC §3.4)" do
    test "await returns the result of a completed run" do
      {:ok, run} = Runner.start_run(sequential_graph(), %{})

      assert {:ok, %{result: "HELLO"}} = Runner.await(run)
    end

    test "the run is not linked to the owner (nolink + monitor)" do
      {:links, links_before} = Process.info(self(), :links)

      {:ok, run} = Runner.start_run(sequential_graph(), %{})

      assert {:links, ^links_before} = Process.info(self(), :links)
      assert {:ok, _state} = Runner.await(run)
    end
  end

  describe "cancel (SPEC §3.9)" do
    test "Ctx.cancelled? is false during normal execution" do
      graph = single_node_graph(&TestNodes.cancel_probe/2)

      assert {:ok, %{result: false}} = ElGraph.invoke(graph, %{})
    end

    test "cooperative node sees the cancel flag and the run ends cancelled" do
      graph = single_node_graph(&TestNodes.wait_for_cancel/2)

      {:ok, run} = Runner.start_run(graph, %{}, event_sink: self())
      assert_receive {:el_graph_event, %{event: :running}}

      assert :ok = Runner.cancel(run)
      assert {:error, :cancelled} = Runner.await(run)
    end

    test "non-cooperative node is brutally killed after the grace period" do
      graph = single_node_graph(&TestNodes.hang/2)

      {:ok, run} = Runner.start_run(graph, %{}, event_sink: self())
      assert_receive {:el_graph_event, %{event: :running}}

      assert :ok = Runner.cancel(run, cancel_timeout: 50)
      assert {:error, :killed} = Runner.await(run)
    end
  end
end
