defmodule ElGraph.Signal.BusTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus

  defp wait_empty(bus, attempts \\ 100) do
    cond do
      Registry.lookup(bus, :subscribers) == [] ->
        :ok

      attempts == 0 ->
        flunk("subscribers not cleaned up")

      true ->
        receive do
        after
          5 -> :ok
        end

        wait_empty(bus, attempts - 1)
    end
  end

  setup do
    bus = :"bus_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus})
    %{bus: bus}
  end

  describe "function subscriptions" do
    test "publish invokes matching function subscribers", %{bus: bus} do
      parent = self()
      Bus.subscribe(bus, "task.*", fn s -> send(parent, {:got, s}) end)

      Bus.publish(bus, %Signal{type: "task.assigned", data: %{n: 1}})

      assert_receive {:got, %Signal{type: "task.assigned", data: %{n: 1}}}
    end

    test "non-matching signals are not delivered", %{bus: bus} do
      parent = self()
      Bus.subscribe(bus, "task.*", fn s -> send(parent, {:got, s}) end)

      Bus.publish(bus, %Signal{type: "chat.message"})

      refute_receive {:got, _}, 50
    end

    test "fans out to all matching subscribers", %{bus: bus} do
      parent = self()
      Bus.subscribe(bus, "*", fn s -> send(parent, {:a, s}) end)
      Bus.subscribe(bus, "task.*", fn s -> send(parent, {:b, s}) end)

      Bus.publish(bus, %Signal{type: "task.done"})

      assert_receive {:a, %Signal{type: "task.done"}}
      assert_receive {:b, %Signal{type: "task.done"}}
    end
  end

  describe "subscriber cleanup" do
    test "a dead subscriber is automatically removed", %{bus: bus} do
      parent = self()

      sub =
        spawn(fn ->
          Bus.subscribe(bus, "task.*", fn s -> send(parent, {:got, s}) end)
          send(parent, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      ref = Process.monitor(sub)
      send(sub, :stop)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}

      # Registry의 구독 정리는 DOWN 처리 후 비동기로 일어난다 — 비워질 때까지 기다린다.
      wait_empty(bus)

      Bus.publish(bus, %Signal{type: "task.x"})
      refute_receive {:got, _}, 50
    end
  end

  describe "Agent subscriptions (발견 8 해소)" do
    defmodule Echo do
      use ElGraph.Agent
      @impl true
      def handle_signal(%Signal{} = s, ctx) do
        send(ctx.opts[:owner], {:agent_got, s})
        :ignore
      end
    end

    def noop(_state, _ctx), do: %{}

    test "an agent self-subscribes via the :subscribe option and receives matching signals", %{
      bus: bus
    } do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:n, &__MODULE__.noop/2)
        |> ElGraph.compile(entry: :n)

      start_supervised!(
        {Echo, graph: graph, id: "sub-echo", owner: self(), subscribe: {bus, "question.*"}}
      )

      Bus.publish(bus, %Signal{type: "question.asked", data: %{q: "hi"}})
      assert_receive {:agent_got, %Signal{type: "question.asked"}}

      Bus.publish(bus, %Signal{type: "other.thing"})
      refute_receive {:agent_got, %Signal{type: "other.thing"}}, 50
    end

    test "supports multiple subscriptions", %{bus: bus} do
      graph =
        ElGraph.new()
        |> ElGraph.state(:x)
        |> ElGraph.add_node(:n, &__MODULE__.noop/2)
        |> ElGraph.compile(entry: :n)

      start_supervised!(
        {Echo,
         graph: graph,
         id: "multi",
         owner: self(),
         subscribe: [{bus, "question.*"}, {bus, "command.*"}]}
      )

      Bus.publish(bus, %Signal{type: "command.run"})
      assert_receive {:agent_got, %Signal{type: "command.run"}}
    end
  end
end
