defmodule ElGraph.Signal.BusTelemetryTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus

  setup do
    bus = :"bus_tel_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus})
    %{bus: bus}
  end

  test "publish emits a bus.publish event with the signal type and matched count", %{bus: bus} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :bus, :publish]])

    parent = self()
    Bus.subscribe(bus, "task.*", fn s -> send(parent, {:got, s}) end)

    Bus.publish(bus, %Signal{type: "task.assigned", data: %{n: 1}})

    assert_receive {[:el_graph, :bus, :publish], ^ref, %{subscribers: 1},
                    %{type: "task.assigned", transport: :local}}
  end
end
