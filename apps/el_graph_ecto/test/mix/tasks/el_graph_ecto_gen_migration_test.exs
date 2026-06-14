defmodule Mix.Tasks.ElGraph.Ecto.Gen.MigrationTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ElGraph.Ecto.Gen.Migration

  test "migration_contents/1 renders a migration delegating to ElGraphEcto.Migration" do
    out = Migration.migration_contents(MyApp.Repo.Migrations.CreateElGraphCheckpoints)

    assert out =~ "defmodule MyApp.Repo.Migrations.CreateElGraphCheckpoints do"
    assert out =~ "use Ecto.Migration"
    assert out =~ "defdelegate change, to: ElGraphEcto.Migration"

    # 생성물이 실제로 컴파일 가능한 코드여야 한다.
    assert [{mod, _bin}] = Code.compile_string(out)
    assert function_exported?(mod, :change, 0)
  after
    :code.purge(MyApp.Repo.Migrations.CreateElGraphCheckpoints)
    :code.delete(MyApp.Repo.Migrations.CreateElGraphCheckpoints)
  end
end
