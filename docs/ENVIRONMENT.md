# 개발 환경 설정 (Windows)

ElGraph 개발에 필요한 Elixir 툴체인 설치와 검증 절차. 2026-06-11 기준으로 이 머신에 구축된 환경을 그대로 기록한다.

## 설치된 버전

| 구성요소 | 버전 | 비고 |
|---|---|---|
| Elixir | **1.20.1** | 최신 릴리스 (2026-06-09 공개) — 확인 완료 |
| Erlang/OTP | **28.5** (erts-16.4) | scoop main 버킷 최신 |
| 패키지 매니저 | scoop | 사용자 권한 설치 (관리자 불필요) |
| Hex | 2.4.2 | `mix local.hex` |
| rebar3 | 설치됨 | `mix local.rebar` (Erlang 의존성 빌드용) |

> `elixir --version`이 "compiled with Erlang/OTP 27"로 표시되는 것은 정상이다 — hex.pm의 프리컴파일 빌드가 OTP 27 타깃일 뿐, OTP 28에서 문제없이 동작한다.

프로젝트 요구사항: `mix.exs`의 `elixir: "~> 1.18"` (내장 `JSON` 모듈 사용을 위해 1.18 이상 필수).

## 처음부터 설치하는 절차

PowerShell에서 (관리자 권한 불필요):

```powershell
# 1. scoop 설치
Invoke-RestMethod get.scoop.sh | Invoke-Expression

# 2. Erlang + Elixir 설치 (7zip은 자동 동반 설치)
scoop install erlang elixir

# 3. 새 터미널을 열고 확인
elixir --version
mix --version

# 4. 빌드 도구 설치
mix local.hex --force
mix local.rebar --force
```

> winget(`Erlang.ErlangOTP`)도 가능하지만 관리자 권한(UAC)이 필요해 비대화형 환경에서 막힌다. scoop을 권장.

## PATH 주의사항

scoop은 두 경로를 사용자 PATH에 등록한다:

- `%USERPROFILE%\scoop\shims` — `erl`, `erlc`, `escript` (Erlang)
- `%USERPROFILE%\scoop\apps\elixir\current\bin` — `elixir`, `mix`, `iex` (**shims가 아님**)

**설치 이전에 열린 터미널/세션에는 적용되지 않는다.** 새 터미널을 열거나, 기존 세션에서는:

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:USERPROFILE\scoop\apps\elixir\current\bin;$env:Path"
```

## 프로젝트 명령

우산 프로젝트다 — 루트에서 실행하면 `apps/el_graph`·`apps/el_trace` 모두에 적용된다.

```powershell
mix deps.get      # 의존성 설치 (el_graph 코어 + el_trace의 Phoenix/LiveView)
mix test          # 테스트 (전부 async: true) — 두 앱 모두
mix format        # 포매터 — 커밋 전 필수
```

단일 테스트 파일은 해당 앱 디렉터리에서 실행한다 (`mix cmd --cd`는 Windows에서 `mix.bat`
실행 권한 오류로 실패):

```powershell
Set-Location apps\el_trace; mix test test/el_trace/sessions_test.exs
```

### ElTrace 웹 UI 실행

```powershell
Set-Location apps\el_trace; mix phx.server   # http://localhost:4000
```

처음 한 번은 esbuild 바이너리를 받는다(`mix esbuild.install`). dev 환경은 승인 대기 thread를
시드해 페이지에 바로 표시한다. (참고: Windows에서 심볼릭 링크 권한이 없으면 Phoenix가 정적 자산을
비워 서빙할 수 있다 — 터미널을 한 번 "관리자 권한으로 실행"하면 해소된다.)

## 업데이트 / 버전 확인

```powershell
scoop status                  # 설치된 패키지가 최신인지 확인
scoop update erlang elixir    # 업데이트
```

최신 릴리스 확인: [Elixir releases](https://github.com/elixir-lang/elixir/releases), [Erlang/OTP releases](https://github.com/erlang/otp/releases)

## 알려진 참고사항

- scoop이 `extras/vcredist2022` 설치를 권장으로 표시한다. Erlang 일부 NIF 실행에 Visual C++ 재배포 패키지가 필요할 수 있는데, 현재까지 컴파일·테스트에는 불필요했다. NIF 의존성을 추가할 때 재검토.
- Erlang 설치 중 "Must be administrator to create link, copying erl.exe instead" 경고는 무해하다 (심볼릭 링크 대신 복사로 대체됨).
- elixir-thinking 스킬이 권하는 `unbuffer`(expect 패키지)는 macOS/Linux 전용이다. Windows에서는 그냥 `mix test`를 쓴다.
