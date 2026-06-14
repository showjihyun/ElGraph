defmodule ElGraph.ReducersTest do
  use ExUnit.Case, async: true

  alias ElGraph.Reducers

  describe "merge/2" do
    test "merges maps, new value wins on key conflict" do
      assert %{a: 1, b: 3, c: 4} = Reducers.merge(%{a: 1, b: 2}, %{b: 3, c: 4})
    end

    test "an empty new map keeps the current value" do
      assert %{a: 1} = Reducers.merge(%{a: 1}, %{})
    end
  end

  describe "append/2" do
    test "wraps a non-list value as a single element" do
      assert ["a", "b"] = Reducers.append(["a"], "b")
    end

    test "concatenates lists" do
      assert [1, 2, 3] = Reducers.append([1], [2, 3])
    end
  end

  describe "append_trim/3 (SPEC §3.1 컨텍스트 압축 1단계)" do
    test "appends then keeps only the last n elements" do
      assert [3, 4, 5] = Reducers.append_trim([1, 2, 3, 4], 5, 3)
    end

    test "wraps non-list values and keeps everything under the limit" do
      assert [1, 2] = Reducers.append_trim([1], 2, 10)
    end
  end

  describe "add/2" do
    test "sums integers and floats" do
      assert 3 = Reducers.add(1, 2)
      assert 3.5 = Reducers.add(1, 2.5)
    end
  end
end
