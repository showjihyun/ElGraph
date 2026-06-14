defmodule ElGraph.Store.ETSTest do
  use ExUnit.Case, async: true

  alias ElGraph.Store.ETS

  setup do
    pid = start_supervised!(ETS)
    %{mod: ETS, config: ETS.config(pid)}
  end

  use ElGraph.StoreContract

  test "two instances do not share data", %{mod: mod, config: config} do
    pid2 = start_supervised!({ETS, []}, id: :store2)
    config2 = ETS.config(pid2)

    :ok = mod.put(config, ["n"], "k", "v")
    assert {:ok, "v"} = mod.get(config, ["n"], "k")
    assert :not_found = mod.get(config2, ["n"], "k")
  end
end
