defmodule ElGraph.Signal.IdempotencyTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal
  alias ElGraph.Signal.Bus

  describe "Signal.ensure_id/1" do
    test "assigns an id when missing and is idempotent" do
      s = Signal.ensure_id(%Signal{type: "t"})
      assert is_binary(s.id) and s.id != ""
      assert ^s = Signal.ensure_id(s)
    end

    test "preserves an existing id" do
      assert %Signal{id: "fixed"} = Signal.ensure_id(%Signal{type: "t", id: "fixed"})
    end

    test "generates distinct ids" do
      refute Signal.ensure_id(%Signal{type: "t"}).id == Signal.ensure_id(%Signal{type: "t"}).id
    end
  end

  describe "publish stamps a delivery id" do
    setup do
      bus = :"bus_#{System.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus})
      %{bus: bus}
    end

    test "an un-id'd published signal reaches every subscriber with the same id", %{bus: bus} do
      parent = self()
      :ok = Bus.subscribe(bus, "t", fn s -> send(parent, {:a, s}) end)
      :ok = Bus.subscribe(bus, "t", fn s -> send(parent, {:b, s}) end)

      :ok = Bus.publish(bus, %Signal{type: "t"})

      assert_receive {:a, %Signal{id: id_a}}
      assert_receive {:b, %Signal{id: id_b}}
      assert is_binary(id_a) and id_a == id_b
    end
  end
end
