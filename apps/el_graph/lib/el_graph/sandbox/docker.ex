defmodule ElGraph.Sandbox.Docker do
  @moduledoc """
  `docker run`으로 코드를 격리 실행하는 `ElGraph.Sandbox` 어댑터.

  `ElGraph.Sandbox.Command`와 달리 **안전 기본값으로 강한 격리를 강제**한다:

    * `--network=none` — 네트워크 차단 (`:network`로 재정의 가능).
    * `--read-only` — 루트 파일시스템 읽기 전용.
    * `--memory=256m` — 메모리 상한 (`:memory`).
    * `--cpus=1` — CPU 상한 (`:cpus`).
    * `--rm` — 종료(타임아웃 포함) 시 컨테이너 자동 정리.

  `:timeout` 초과 시 `ElGraph.Sandbox`의 공용 Task 래퍼로 러너를 죽이며, `--rm` 덕분에
  컨테이너도 정리된다(Command의 best-effort 정리보다 강하다).

  `:runner`(테스트 주입용, 기본 `System.cmd`)로 실행을 가로챌 수 있다.

  지원 언어: `"elixir"`, `"python"`, `"node"`, `"ruby"`, `"bash"`.

  ## 옵션

    * `:language` — 인터프리터 선택 (기본 `"elixir"`).
    * `:image` — 컨테이너 이미지 (기본은 언어별, 아래 참조).
    * `:network` — `--network` 값 (기본 `"none"`).
    * `:memory` — `--memory` 값 (기본 `"256m"`).
    * `:cpus` — `--cpus` 값 (기본 `"1"`).
    * `:timeout` — 실행 제한(ms, 기본 `:infinity`). 초과 시 `{:error, :timeout}`.
    * `:max_output` — stdout 최대 바이트(기본 `:infinity`). 초과하면 잘라내고 `truncated: true`.
    * `:runner` — `(cmd, args, opts) -> {output, exit_code}` (기본 `System.cmd/3`).
  """

  @behaviour ElGraph.Sandbox

  alias ElGraph.Sandbox

  @default_images %{
    "elixir" => "elixir:1.18-slim",
    "python" => "python:3.12-slim",
    "node" => "node:22-slim",
    "ruby" => "ruby:3.3-slim",
    "bash" => "bash:5"
  }

  # Docker 고유분만 — 안전 기본값을 강제하는 docker run argv 조립. 언어 lookup·실행·result
  # 매핑은 Sandbox 공용 헬퍼가 맡는다.
  @impl ElGraph.Sandbox
  def run(code, opts \\ []) when is_binary(code) do
    language = opts[:language] || "elixir"

    with {:ok, {interpreter, flag}} <- Sandbox.interpreter(language) do
      image = opts[:image] || Map.fetch!(@default_images, language)
      Sandbox.exec("docker", docker_args(image, interpreter, flag, code, opts), opts)
    end
  end

  defp docker_args(image, interpreter, flag, code, opts) do
    [
      "run",
      "--rm",
      "--network=#{opts[:network] || "none"}",
      "--read-only",
      "--memory=#{opts[:memory] || "256m"}",
      "--cpus=#{opts[:cpus] || "1"}",
      image,
      interpreter,
      flag,
      code
    ]
  end
end
