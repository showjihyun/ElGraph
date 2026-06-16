defmodule ElGraph.Signal.DedupTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal.Dedup

  test "first put is :new, a repeat of the same id is :duplicate" do
    d = Dedup.new()
    assert {:new, d} = Dedup.put(d, "a")
    assert {:duplicate, d} = Dedup.put(d, "a")
    assert {:new, _d} = Dedup.put(d, "b")
  end

  test "evicts the oldest id beyond max (bounded memory)" do
    d = Dedup.new(2)
    {:new, d} = Dedup.put(d, "a")
    {:new, d} = Dedup.put(d, "b")
    # "c" pushes out the oldest ("a")
    {:new, d} = Dedup.put(d, "c")

    assert {:duplicate, d} = Dedup.put(d, "c")
    assert {:duplicate, d} = Dedup.put(d, "b")
    # "a" was evicted → seen as new again (bounded trade-off)
    assert {:new, _d} = Dedup.put(d, "a")
  end
end
