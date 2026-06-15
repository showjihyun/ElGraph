defmodule ElGraph.Secrets do
  @moduledoc """
  통합 테스트용 비밀 설정 로더.

  해석 순서:
    1. 환경변수 — 키를 대문자화해 조회 (`:openai_api_key` → `OPENAI_API_KEY`). CI에서 GitHub
       Secrets로 주입할 때 사용한다.
    2. `config/secrets.exs`(gitignore됨) — 로컬 개발용. 테스트 CWD가 움브렐라 루트든 앱
       디렉터리(`apps/<app>`)든 무관하게 루트의 파일을 찾는다.

      api_key = ElGraph.Secrets.fetch!(:openai_api_key)
  """

  # CWD가 루트든 `apps/<app>`이든 동일한 루트 secrets.exs를 가리킨다.
  @candidates ["config/secrets.exs", Path.join(["..", "..", "config", "secrets.exs"])]

  def fetch!(key) do
    case from_env(key) || from_file()[key] do
      nil ->
        raise "#{inspect(key)}가 없습니다 — 환경변수 #{env_name(key)} 또는 " <>
                "config/secrets.exs에 등록하세요 (템플릿: config/secrets.example.exs)"

      value ->
        value
    end
  end

  defp from_env(key) do
    case System.get_env(env_name(key)) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp env_name(key), do: key |> Atom.to_string() |> String.upcase()

  defp from_file do
    case Enum.find(@candidates, &File.exists?/1) do
      nil ->
        []

      path ->
        {secrets, _bindings} = Code.eval_file(path)
        secrets
    end
  end
end
