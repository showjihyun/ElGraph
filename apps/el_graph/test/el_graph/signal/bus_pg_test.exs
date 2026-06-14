defmodule ElGraph.Signal.BusPgTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus

  defmodule Echo do
    use ElGraph.Agent
    @impl true
    def handle_signal(%Signal{} = s, ctx) do
      send(ctx.opts[:owner], {:agent_got, s})
      :ignore
    end
  end

  setup do
    bus = :"pgbus_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus, transport: :pg})
    on_exit(fn -> ElGraph.Signal.Bus.Pg.reset(bus) end)
    %{bus: bus}
  end

  defp echo_graph do
    ElGraph.new()
    |> ElGraph.state(:x)
    |> ElGraph.add_node(:n, &__MODULE__.noop/2)
    |> ElGraph.compile(entry: :n)
  end

  def noop(_state, _ctx), do: %{}

  describe ":pg transport (SPEC §6)" do
    test "delivers signals to agent subscribers (single node)", %{bus: bus} do
      start_supervised!(
        {Echo, graph: echo_graph(), id: "pg-echo", owner: self(), subscribe: {bus, "task.*"}}
      )

      Bus.publish(bus, %Signal{type: "task.run", data: %{n: 1}})
      assert_receive {:agent_got, %Signal{type: "task.run", data: %{n: 1}}}
    end

    test "respects pattern matching across the pg scope", %{bus: bus} do
      start_supervised!(
        {Echo, graph: echo_graph(), id: "pg-e2", owner: self(), subscribe: {bus, "task.*"}}
      )

      Bus.publish(bus, %Signal{type: "chat.msg"})
      refute_receive {:agent_got, _}, 50

      Bus.publish(bus, %Signal{type: "task.x"})
      assert_receive {:agent_got, %Signal{type: "task.x"}}
    end

    test "fans out to multiple agent subscribers", %{bus: bus} do
      for id <- ["a", "b"] do
        start_supervised!(
          {Echo, graph: echo_graph(), id: "fan-#{id}", owner: self(), subscribe: {bus, "*"}},
          id: String.to_atom("fan_#{id}")
        )
      end

      Bus.publish(bus, %Signal{type: "broadcast"})
      assert_receive {:agent_got, %Signal{type: "broadcast"}}
      assert_receive {:agent_got, %Signal{type: "broadcast"}}
    end

    test "function subscriptions are rejected on a pg bus", %{bus: bus} do
      assert_raise ArgumentError, ~r/function subscriptions require a :local bus/, fn ->
        Bus.subscribe(bus, "task.*", fn _s -> :ok end)
      end
    end
  end
end
