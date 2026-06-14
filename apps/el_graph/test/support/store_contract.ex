defmodule ElGraph.StoreContract do
  @moduledoc """
  모든 Store 어댑터가 통과해야 하는 공유 계약 테스트 (SPEC §6).

  사용하는 테스트 모듈은 `setup`에서 `%{mod: 어댑터, config: 설정}`을 제공해야 한다.
  """

  defmacro __using__(_opts) do
    quote do
      describe "store contract" do
        test "put then get roundtrips", %{mod: mod, config: config} do
          assert :ok = mod.put(config, ["users", "u1"], "theme", "dark")
          assert {:ok, "dark"} = mod.get(config, ["users", "u1"], "theme")
        end

        test "get of a missing key is :not_found", %{mod: mod, config: config} do
          assert :not_found = mod.get(config, ["users", "ghost"], "theme")
        end

        test "put overwrites an existing value", %{mod: mod, config: config} do
          :ok = mod.put(config, ["n"], "k", 1)
          :ok = mod.put(config, ["n"], "k", 2)
          assert {:ok, 2} = mod.get(config, ["n"], "k")
        end

        test "namespaces are isolated", %{mod: mod, config: config} do
          :ok = mod.put(config, ["a"], "k", "av")
          :ok = mod.put(config, ["b"], "k", "bv")

          assert {:ok, "av"} = mod.get(config, ["a"], "k")
          assert {:ok, "bv"} = mod.get(config, ["b"], "k")
        end

        test "delete removes a key", %{mod: mod, config: config} do
          :ok = mod.put(config, ["n"], "k", "v")
          :ok = mod.delete(config, ["n"], "k")
          assert :not_found = mod.get(config, ["n"], "k")
        end

        test "list returns all key/value pairs in a namespace", %{mod: mod, config: config} do
          :ok = mod.put(config, ["docs"], "a", 1)
          :ok = mod.put(config, ["docs"], "b", 2)
          :ok = mod.put(config, ["other"], "c", 3)

          pairs = mod.list(config, ["docs"]) |> Enum.sort()
          assert [{"a", 1}, {"b", 2}] = pairs
          assert [] = mod.list(config, ["empty"])
        end
      end
    end
  end
end
