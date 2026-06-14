defmodule ElGraph.Actions.CodeExec do
  @moduledoc """
  에이전트 생성 코드를 격리 실행하는 Action (트렌드 보고서 Tier 3.10).

  스키마 하나에서 파라미터 검증 + LLM tool 스펙을 만들고, 실제 실행은 설정된 `ElGraph.Sandbox`
  백엔드에 위임한다 — **인프로세스 eval은 절대 하지 않는다**. 백엔드 미설정 시 명확히 에러.

  백엔드 해석 순서:
    1. `context[:sandbox]` (`{module, opts}`) — 호출 시 주입
    2. `Application.get_env(:el_graph, :code_exec_sandbox)`
    3. 없음 → `{:error, :no_sandbox_configured}`
  """

  use ElGraph.Action,
    name: "code_exec",
    description: "Executes code in an isolated sandbox and returns its stdout.",
    schema: [
      code: [type: :string, required: true, doc: "Source code to run."],
      language: [type: :string, doc: "elixir | python | node | ruby | bash (default elixir)."]
    ]

  @impl ElGraph.Action
  def run(%{code: code} = params, context) do
    case resolve_backend(context) do
      {module, opts} ->
        backend_opts = Keyword.put(opts, :language, Map.get(params, :language))

        case module.run(code, backend_opts) do
          {:ok, result} -> {:ok, %{result: result}}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        {:error, :no_sandbox_configured}
    end
  end

  defp resolve_backend(%{sandbox: {module, opts}}) when is_atom(module), do: {module, opts}

  defp resolve_backend(_context) do
    case Application.get_env(:el_graph, :code_exec_sandbox) do
      {module, opts} when is_atom(module) -> {module, opts}
      module when is_atom(module) and not is_nil(module) -> {module, []}
      _none -> :none
    end
  end
end
