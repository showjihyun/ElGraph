defmodule ElGraphEcto.StoreMigration do
  @moduledoc """
  `ElGraph.Store.Postgres`(thread를 가로지르는 장기기억)용 테이블 마이그레이션.

  체크포인트 마이그레이션(`ElGraphEcto.Migration`)과 별개 기능이라 별도 마이그레이션이다.
  호스트 앱의 마이그레이션에서 위임 호출:

      defmodule MyApp.Repo.Migrations.CreateElGraphStore do
        use Ecto.Migration
        def change, do: ElGraphEcto.StoreMigration.change()
      end

  `namespace`는 `text[]`(예: `["users","u1"]`)로 저장해 구분자 충돌 없이 계층을 보존한다.
  `value`는 `:erlang.term_to_binary/1` 직렬화(bytea) — atom/tuple/map 등 Elixir 항을 손실 없이.
  """
  use Ecto.Migration

  def change do
    create table(:el_graph_store, primary_key: false) do
      add :namespace, {:array, :text}, null: false
      add :key, :text, null: false
      add :value, :binary, null: false
    end

    create unique_index(:el_graph_store, [:namespace, :key])
  end
end
