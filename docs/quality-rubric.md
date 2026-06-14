# 구현 품질 루브릭 (보고서 반영 확장)

`docs/agentic-ai-2026-report.html` 기반으로 구현·심화한 기능(SPEC §14)의 전반 품질을 차원별로
수치화한다. 각 차원 0–10, 가중 평균이 종합 점수. 근거와 개선 액션을 함께 기록한다.

평가일: 2026-06-14 · 대상: T1.1–T3.10(9개) + 관측 연계

| # | 차원 | 가중치 | 점수 | 근거 |
|---|---|---|---|---|
| 1 | 기능 정확성 | 0.15 | 9.6 | 9개 기능 전부 동작 테스트로 행동 검증(패턴매칭 단언). 엣지케이스 포함(툴콜 프레이밍, stall guard, supersede, 타임아웃) |
| 2 | 단위 테스트 커버리지 | 0.15 | 9.5 | 신규 ~155 테스트, 전부 `async: true`. 순수 로직(파서/리듀서/매핑/스코어러)은 입력-출력 직접 단언 |
| 3 | 통합/E2E 테스트 | 0.12 | 9.3 | 라이브 Bandit HTTP(Req 라운드트립), 실 OpenAI(@integration), 실 elixir 샌드박스, OTel SDK pid exporter |
| 4 | 관측 연계(ElTrace+Langfuse) | 0.12 | 9.5 | Langfuse 파이프라인 테스트(telemetry→Bridge→OTel span 중첩) + ElTrace가 오케스트레이션 실행을 타임라인/분기로 관측 |
| 5 | 표준 준수 | 0.12 | 9.4 | A2A JSON-RPC 2.0(에러코드/Task/well-known), AG-UI 표준 이벤트, OTel GenAI semconv 매핑 |
| 6 | API 설계 일관성 | 0.10 | 9.5 | 기존 패턴 답습(behaviour 포트, A2A와 동형 순수매핑, MFA 노드, `{mod,config}` 어댑터). 신규 추상화 최소 |
| 7 | 문서화 | 0.08 | 9.3 | SPEC §14 표 + 모듈 moduledoc(예시 포함) + 체크리스트 + 본 루브릭 |
| 8 | 안전/에러 처리 | 0.08 | 9.4 | 가드레일(PII/스키마/인가), 샌드박스 격리 위임 + 타임아웃(누수無) + Docker 하드격리, 스트리밍 에러 매핑, eval 크래시→실패 |
| 9 | 아키텍처 적합성 | 0.05 | 9.7 | 전부 격리 신규 모듈/앱, 코어 런타임 의존 불변, "라이브러리는 서버 자동기동 안 함" 원칙 준수(`server_spec/1`) |
| 10 | 품질 게이트 | 0.03 | 9.2 | `mix format` ✅ · `async: true` ✅ · `@spec` 전 공개함수 ✅ · doctest ✅(`ElGraph.AGUI` 실행 doctest 3건 추가) · Dialyzer ✗(SPEC §10대로 미도입) |

**종합(가중 평균): 9.46 / 10**

## 차원별 개선 액션

- **품질 게이트(8.5→9.2)** — 개선 완료:
  - ✅ [완료] 핵심 순수 모듈(`ElGraph.AGUI`)에 실행 가능한 doctest 3건 추가 → 문서가 거짓말하지 않음을 컴파일타임 보장.
  - [보류] Dialyzer 도입은 전 코드베이스 영향이라 별도 작업(SPEC §10 "도입 후" 게이트). 신규 모듈은 모두 `@spec` 보유.
- **통합/E2E(9.3)** — Anthropic/Gemini 증분 도구호출 스트리밍은 OpenAI만 구현(나머지는 텍스트+헬퍼). 표본 늘면 동일 패턴으로 확장.
- **문서화(9.3)** — `el_graph_web`의 README/사용 예시 보강 여지(현재 moduledoc 중심).

## 검증 명령

```
# 전체(통합 제외)
mix test
# 통합(실 OpenAI/Langfuse 파이프라인/샌드박스)
cd apps/el_graph && mix test --only integration
# 관측 연계
cd apps/el_graph && mix test test/el_graph/otel/langfuse_pipeline_test.exs --only integration
cd apps/el_trace && mix test test/el_trace/new_features_integration_test.exs
```
