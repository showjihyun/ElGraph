defmodule Mix.Tasks.ElGraph.Ecto.Gen.Migration do
  @shortdoc "ElGraph 체크포인트 테이블 마이그레이션을 호스트 Repo에 생성한다"

  @moduledoc """
  ElGraph 체크포인트/pending writes 테이블을 만드는 Ecto 마이그레이션을 생성한다.

      mix el_graph.ecto.gen.migration -r MyApp.Repo

  생성되는 마이그레이션은 스키마 정의를 `ElGraphEcto.Migration`에 위임하므로,
  스키마가 바뀌어도 호스트 마이그레이션 파일은 그대로 둔다. 이후 `mix ecto.migrate`로 적용한다.
  """

  use Mix.Task

  import Mix.Generator
  import Mix.Ecto

  @impl Mix.Task
  def run(args) do
    repos = parse_repo(args)

    Enum.each(repos, fn repo ->
      path = Path.join(Mix.EctoSQL.source_repo_priv(repo), "migrations")
      create_directory(path)

      mod = Module.concat([repo, Migrations, CreateElGraphCheckpoints])
      target = Path.join(path, "#{timestamp()}_create_el_graph_checkpoints.exs")
      create_file(target, migration_contents(mod))
    end)
  end

  @doc false
  def migration_contents(mod) do
    """
    defmodule #{inspect(mod)} do
      use Ecto.Migration

      # ElGraph 체크포인트/pending writes 테이블. 스키마 정의는 ElGraphEcto.Migration이 소유한다.
      defdelegate change, to: ElGraphEcto.Migration
    end
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"
end
