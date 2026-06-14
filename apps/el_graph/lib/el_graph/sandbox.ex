defmodule ElGraph.Sandbox do
  @moduledoc """
  격리된 코드 실행 behaviour (트렌드 보고서 Tier 3.10).

  2026 트렌드: 빅3 SDK 전부 에이전트 생성 코드의 샌드박스 실행을 내장한다. ElGraph는
  **인프로세스 eval을 하지 않는다**(BEAM 내 안전한 샌드박싱은 어렵다) — 대신 격리를 외부
  샌드박스(컨테이너/마이크로VM/원격 서비스/MCP 툴)에 위임하는 behaviour만 정의한다.

  ## 격리 모델 (어댑터별 안전 기본값)

    * `ElGraph.Sandbox.Command` — 외부 인터프리터에 위임할 뿐 **자체 격리가 전혀 없다**
      (네트워크/파일시스템/리소스 무제한). 반드시 컨테이너/제한된 사용자/마이크로VM 안에서
      구동되어야 안전하다. `:timeout`은 Task를 죽여 best-effort로만 정리하며, 이미 떠 있는
      OS 서브프로세스 종료는 보장하지 않는다.
    * `ElGraph.Sandbox.Docker` — `docker run` 기본값으로 **네트워크 차단(`--network=none`),
      읽기 전용 루트 FS(`--read-only`), 메모리/CPU 제한**을 강제한다. 타임아웃 시 컨테이너가
      `--rm`으로 정리되므로 Command보다 훨씬 강한 격리를 제공한다.

  `ElGraph.Actions.CodeExec`가 이 behaviour를 LLM 툴로 노출한다.
  """

  @type result :: %{
          stdout: String.t(),
          exit_code: integer(),
          truncated: boolean()
        }

  @callback run(code :: String.t(), opts :: keyword()) :: {:ok, result()} | {:error, term()}

  @doc false
  # 어댑터 공용 타임아웃 래퍼. 러너를 Task 안에서 실행하고, `:timeout`(ms, 기본 `:infinity`)을
  # 초과하면 `Task.shutdown(task, :brutal_kill)`로 정리한 뒤 `{:error, :timeout}`을 돌려준다.
  # 정상 종료 시 `{:ok, {output, exit_code}}`. 프로세스 누수를 막기 위해 항상 shutdown한다.
  @spec run_with_timeout(
          (String.t(), [String.t()], keyword() -> {String.t(), integer()}),
          String.t(),
          [String.t()],
          keyword()
        ) :: {:ok, {String.t(), integer()}} | {:error, :timeout}
  def run_with_timeout(runner, cmd, args, opts) do
    timeout = opts[:timeout] || :infinity

    task = Task.async(fn -> runner.(cmd, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> {:error, :timeout}
    end
  end
end
