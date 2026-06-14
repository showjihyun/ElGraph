defmodule ElGraph.CheckpointTest do
  use ExUnit.Case, async: true

  alias ElGraph.Checkpoint

  describe "validate_serializable/1 (SPEC §3.8)" do
    test "accepts plain data: scalars, lists, tuples, maps, structs" do
      assert :ok =
               Checkpoint.validate_serializable(%{
                 a: [1, "x", :y, {1.5, nil}],
                 b: %{c: true}
               })

      assert :ok = Checkpoint.validate_serializable(%Checkpoint{thread_id: "t", state: %{x: 1}})
    end

    test "accepts remote function captures" do
      assert :ok = Checkpoint.validate_serializable(%{reducer: &ElGraph.Reducers.append/2})
    end

    test "rejects a top-level pid" do
      pid = self()

      assert {:error, {:not_serializable, ^pid}} = Checkpoint.validate_serializable(pid)
    end

    test "rejects a reference" do
      ref = make_ref()

      assert {:error, {:not_serializable, ^ref}} = Checkpoint.validate_serializable(%{r: ref})
    end

    test "rejects a local anonymous function" do
      fun = fn -> :ok end

      assert {:error, {:not_serializable, ^fun}} = Checkpoint.validate_serializable([fun])
    end

    test "rejects non-serializable values nested deep in tuples and structs" do
      ref = make_ref()

      assert {:error, {:not_serializable, ^ref}} =
               Checkpoint.validate_serializable(%{a: [1, {2, [ref]}]})

      assert {:error, {:not_serializable, ^ref}} =
               Checkpoint.validate_serializable(%Checkpoint{state: %{x: ref}})
    end
  end
end
