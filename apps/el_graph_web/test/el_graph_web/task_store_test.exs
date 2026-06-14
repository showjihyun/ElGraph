defmodule ElGraphWeb.TaskStoreTest do
  use ExUnit.Case, async: true

  alias ElGraphWeb.TaskStore

  setup do
    %{store: start_supervised!(TaskStore)}
  end

  test "put then get round-trips a task", %{store: store} do
    task = %{"id" => "t1", "status" => %{"state" => "completed"}}
    assert :ok = TaskStore.put(store, task)
    assert {:ok, ^task} = TaskStore.get(store, "t1")
  end

  test "get for unknown id → :error", %{store: store} do
    assert :error = TaskStore.get(store, "missing")
  end
end
