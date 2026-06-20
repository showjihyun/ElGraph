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

  # 어댑터 공용 인터프리터 테이블 — Command/Docker가 동일하게 쓴다.
  @interpreters %{
    "elixir" => {"elixir", "-e"},
    "python" => {"python", "-c"},
    "node" => {"node", "-e"},
    "ruby" => {"ruby", "-e"},
    "bash" => {"bash", "-c"}
  }

  @doc false
  @spec interpreter(String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, {:unsupported_language, String.t()}}
  def interpreter(language) do
    case Map.fetch(@interpreters, language) do
      {:ok, cmd_flag} -> {:ok, cmd_flag}
      :error -> {:error, {:unsupported_language, language}}
    end
  end

  @doc false
  # 어댑터 공용 실행. 러너(`:runner`, 기본 `System.cmd`)를 timeout 안에서 돌리고 결과를 중립
  # result로 매핑한다: exit 0 = 성공(`:max_output` 적용), 그 외 = `{:error, {:exit, code, output}}`,
  # timeout = `{:error, :timeout}`. Command/Docker가 cmd/args만 달리해 호출한다.
  @spec exec(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def exec(cmd, args, opts) do
    runner = opts[:runner] || (&default_runner/3)

    case run_with_timeout(runner, cmd, args, opts) do
      {:ok, {output, 0}} -> {:ok, build_result(output, 0, opts)}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  defp build_result(output, code, opts) do
    case opts[:max_output] do
      nil ->
        %{stdout: output, exit_code: code, truncated: false}

      :infinity ->
        %{stdout: output, exit_code: code, truncated: false}

      max when byte_size(output) > max ->
        %{stdout: binary_part(output, 0, max), exit_code: code, truncated: true}

      _max ->
        %{stdout: output, exit_code: code, truncated: false}
    end
  end

  defp default_runner(cmd, args, opts), do: System.cmd(cmd, args, opts)

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
