defmodule ElGraphEcto.Migration do
  @moduledoc """
  체크포인트/pending writes 테이블을 만드는 Ecto 마이그레이션.

  호스트 앱의 마이그레이션에서 위임 호출:

      defmodule MyApp.Repo.Migrations.CreateElGraphCheckpoints do
        use Ecto.Migration
        def up, do: ElGraphEcto.Migration.up()
        def down, do: ElGraphEcto.Migration.down()
      end

  `data`는 `:erlang.term_to_binary/1`로 직렬화한 체크포인트(bytea). 그래서 atom/tuple/struct 등
  Elixir 항을 손실 없이 보존한다(JSON과 달리).
  """
  use Ecto.Migration

  def change do
    create table(:el_graph_checkpoints, primary_key: false) do
      add :thread_id, :text, null: false
      add :step, :bigint, null: false
      add :version, :integer, null: false
      add :data, :binary, null: false
    end

    create unique_index(:el_graph_checkpoints, [:thread_id, :step])

    create table(:el_graph_writes, primary_key: false) do
      add :thread_id, :text, null: false
      add :step, :bigint, null: false
      add :data, :binary, null: false
    end

    create unique_index(:el_graph_writes, [:thread_id, :step])
  end
end
