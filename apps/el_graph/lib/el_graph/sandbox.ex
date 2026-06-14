defmodule ElGraph.Sandbox do
  @moduledoc """
  격리된 코드 실행 behaviour (트렌드 보고서 Tier 3.10).

  2026 트렌드: 빅3 SDK 전부 에이전트 생성 코드의 샌드박스 실행을 내장한다. ElGraph는
  **인프로세스 eval을 하지 않는다**(BEAM 내 안전한 샌드박싱은 어렵다) — 대신 격리를 외부
  샌드박스(컨테이너/마이크로VM/원격 서비스/MCP 툴)에 위임하는 behaviour만 정의한다.

  기본 어댑터 `ElGraph.Sandbox.Command`는 외부 인터프리터에 위임한다(격리는 호스트의
  컨테이너/권한이 담당). `ElGraph.Actions.CodeExec`가 이 behaviour를 LLM 툴로 노출한다.
  """

  @type result :: %{stdout: String.t(), exit_code: integer()}

  @callback run(code :: String.t(), opts :: keyword()) :: {:ok, result()} | {:error, term()}
end
