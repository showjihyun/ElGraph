defmodule ElGraph.Secrets do
  @moduledoc """
  통합 테스트용 비밀 설정 로더. `config/secrets.exs`(gitignore됨)를 읽는다.

      api_key = ElGraph.Secrets.fetch!(:openai_api_key)
  """

  @path "config/secrets.exs"

  def fetch!(key) do
    case load()[key] do
      nil ->
        raise "#{inspect(key)}가 없습니다 — config/secrets.exs에 등록하세요 " <>
                "(템플릿: config/secrets.example.exs)"

      value ->
        value
    end
  end

  defp load do
    if File.exists?(@path) do
      {secrets, _bindings} = Code.eval_file(@path)
      secrets
    else
      []
    end
  end
end
