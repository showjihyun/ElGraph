defmodule ElGraph.Memory.Backend.NativeTest do
  use ExUnit.Case, async: true

  alias ElGraph.Memory
  alias ElGraph.Memory.Backend
  alias ElGraph.Store.ETS, as: Store

  # Char-frequency embedder — lexically similar text ranks higher.
  defmodule CharEmbedder do
    @behaviour ElGraph.Memory.Embedder

    @impl true
    def embed(text) do
      freq =
        text |> String.downcase() |> String.to_charlist() |> Enum.frequencies()

      for c <- ?a..?z, do: Map.get(freq, c, 0) / 1.0
    end
  end

  @ns ["users", "u1"]

  setup do
    pid = start_supervised!({Store, []})
    mem = Memory.new({Store, Store.config(pid)})
    backend = {Backend.Native, %{memory: mem, embedder: CharEmbedder}}
    %{backend: backend}
  end

  test "remember then recall ranks the relevant memory first", %{backend: backend} do
    :ok = Backend.remember(backend, @ns, "billing and pricing questions", at: 1)
    :ok = Backend.remember(backend, @ns, "quantum field theory lecture", at: 2)

    assert {:ok, ["billing and pricing questions" | _]} =
             Backend.recall(backend, @ns, "billing and pricing questions")
  end

  test "recall honors the limit", %{backend: backend} do
    :ok = Backend.remember(backend, @ns, "alpha", at: 1)
    :ok = Backend.remember(backend, @ns, "alpine", at: 2)
    :ok = Backend.remember(backend, @ns, "almanac", at: 3)

    assert {:ok, results} = Backend.recall(backend, @ns, "alpha", limit: 2)
    assert length(results) == 2
  end

  test "memories are isolated per namespace", %{backend: backend} do
    :ok = Backend.remember(backend, ["users", "a"], "a-only memory", at: 1)
    assert {:ok, []} = Backend.recall(backend, ["users", "b"], "a-only memory")
  end
end
