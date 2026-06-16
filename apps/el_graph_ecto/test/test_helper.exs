alias ElGraphEcto.Repo

# DB가 있으면 Repo 기동 + 마이그레이션 + Sandbox 준비. 없으면 :postgres 태그 제외 후 통과.
db_ok? =
  try do
    case Repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Ecto.Migrator.run(
      Repo,
      [
        {20_260_614_000_001, ElGraphEcto.Migration},
        {20_260_616_000_001, ElGraphEcto.StoreMigration}
      ],
      :up,
      all: true
    )

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    true
  rescue
    e ->
      IO.puts("\n[el_graph_ecto] Postgres 미가용 — :postgres 테스트 건너뜀. (#{Exception.message(e)})\n")
      false
  catch
    kind, reason ->
      IO.puts(
        "\n[el_graph_ecto] Postgres 미가용 — :postgres 테스트 건너뜀. (#{inspect({kind, reason})})\n"
      )

      false
  end

if db_ok? do
  ExUnit.start()
else
  ExUnit.start(exclude: [:postgres])
end
