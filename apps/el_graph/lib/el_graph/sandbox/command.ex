defmodule ElGraph.Sandbox.Command do
  @moduledoc """
  외부 인터프리터에 위임하는 `ElGraph.Sandbox` 어댑터.

  실제 격리는 호스트가 책임진다 — 이 어댑터는 컨테이너/제한된 사용자/마이크로VM 안에서
  구동될 것을 전제로 인터프리터 프로세스를 띄울 뿐, **자체적으로 격리를 보장하지 않는다**
  (네트워크/파일시스템/리소스 제한 없음). 하드 격리가 필요하면 `ElGraph.Sandbox.Docker`를
  사용한다.

  `:runner`(테스트 주입용, 기본 `System.cmd`)로 실행을 가로챌 수 있다.

  지원 언어: `"elixir"`, `"python"`, `"node"`, `"ruby"`, `"bash"`.

  ## 옵션

    * `:language` — 인터프리터 선택 (기본 `"elixir"`).
    * `:timeout` — 실행 제한(ms, 기본 `:infinity`). 초과 시 `{:error, :timeout}`.
      러너를 `Task` 안에서 돌리고 초과 시 `Task.shutdown(task, :brutal_kill)`로 정리한다.
      **주의(best-effort):** 기본 `System.cmd` 러너에서 Task를 죽여도 이미 떠 있는 OS
      서브프로세스는 BEAM이 best-effort로만 정리한다. 하드 격리(서브프로세스 강제 종료
      포함)가 필요하면 `ElGraph.Sandbox.Docker`(컨테이너 단위 정리)를 쓴다.
    * `:max_output` — stdout 최대 바이트(기본 `:infinity`). 초과하면 잘라내고
      `truncated: true`를 반환한다. 자르지 않으면 `truncated: false`.
    * `:runner` — `(cmd, args, opts) -> {output, exit_code}` (기본 `System.cmd/3`).
  """

  @behaviour ElGraph.Sandbox

  alias ElGraph.Sandbox

  # 인터프리터를 직접 실행할 뿐 — 언어 lookup·실행·result 매핑은 Sandbox 공용 헬퍼가 맡는다.
  @impl ElGraph.Sandbox
  def run(code, opts \\ []) when is_binary(code) do
    with {:ok, {cmd, flag}} <- Sandbox.interpreter(opts[:language] || "elixir") do
      Sandbox.exec(cmd, [flag, code], opts)
    end
  end
end
