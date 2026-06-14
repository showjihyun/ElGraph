defmodule ElGraphEcto.Repo do
  @moduledoc """
  ElGraph 체크포인트 영속화용 기본 Ecto Repo(Postgres).

  호스트 앱은 이 Repo를 슈퍼비전 트리에 마운트하고 설정한다(`config :el_graph_ecto, ElGraphEcto.Repo, ...`).
  이미 자체 Repo가 있으면 그 Repo를 `ElGraph.Checkpointer.Postgres.config/1`에 넘겨 재사용해도 된다 —
  어댑터는 어떤 Ecto Repo와도 동작한다(테이블만 있으면).
  """
  use Ecto.Repo,
    otp_app: :el_graph_ecto,
    adapter: Ecto.Adapters.Postgres
end
