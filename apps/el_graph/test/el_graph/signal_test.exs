defmodule ElGraph.SignalTest do
  use ExUnit.Case, async: true

  alias ElGraph.Signal

  describe "matches?/2 (SPEC §5)" do
    test "exact match" do
      assert Signal.matches?("task.assigned", "task.assigned")
      refute Signal.matches?("task.assigned", "task.done")
    end

    test "prefix wildcard" do
      assert Signal.matches?("task.*", "task.assigned")
      assert Signal.matches?("task.*", "task.review.requested")
      refute Signal.matches?("task.*", "chat.message")
      refute Signal.matches?("task.*", "task")
    end

    test "global wildcard matches everything" do
      assert Signal.matches?("*", "anything.at.all")
    end
  end
end
