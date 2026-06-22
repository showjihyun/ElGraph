defmodule ElGraphWeb.TaskStoreTest do
  use ExUnit.Case, async: true

  alias ElGraphWeb.TaskStore

  setup do
    %{store: start_supervised!({TaskStore, name: nil})}
  end

  test "put then get round-trips a task", %{store: store} do
    task = %{"id" => "t1", "status" => %{"state" => "completed"}}
    assert :ok = TaskStore.put(store, task)
    assert {:ok, ^task} = TaskStore.get(store, "t1")
  end

  test "get for unknown id → :error", %{store: store} do
    assert :error = TaskStore.get(store, "missing")
  end

  test "tasks are scoped to their owner — a different owner cannot read them", %{store: store} do
    task = %{"id" => "t1", "status" => %{"state" => "completed"}}
    :ok = TaskStore.put(store, task, "owner-a")

    assert {:ok, ^task} = TaskStore.get(store, "t1", "owner-a")
    assert :error = TaskStore.get(store, "t1", "owner-b")
    assert :error = TaskStore.get(store, "t1", nil)
  end

  test "evicts the oldest task beyond the max size cap (bounded memory)" do
    store = start_supervised!({TaskStore, name: :capped_store, max: 2}, id: :capped)

    for i <- 1..3, do: :ok = TaskStore.put(store, %{"id" => "t#{i}"})

    assert :error = TaskStore.get(store, "t1"), "oldest task should be evicted"
    assert {:ok, _} = TaskStore.get(store, "t2")
    assert {:ok, _} = TaskStore.get(store, "t3")
  end
end
