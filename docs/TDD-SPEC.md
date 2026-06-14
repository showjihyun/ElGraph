# TDD 스펙 (Elixir 전용)

ElGraph의 모든 코드 변경에 적용되는 테스트 주도 개발 규약. 이 문서는 CLAUDE.md에 의해 **모든 구현 작업에 강제**된다.

원칙: 테스트는 SPEC.md의 실행 가능한 형태다. 기능의 완료 기준은 "스펙 조항을 검증하는 테스트가 통과한다"이며, 테스트 없는 구현은 미완성으로 간주한다.

---

## 1. Red–Green–Refactor 루프

모든 기능/버그픽스는 이 순서를 따른다. 단계를 건너뛰지 않는다.

### RED — 실패하는 테스트 먼저

1. 구현할 스펙 조항(SPEC.md §번호)을 테스트 이름/describe에 대응시킨다.
2. 테스트를 작성하고 **실행해서 실패를 확인한다**:
   ```powershell
   mix test test/el_graph/checkpointer_test.exs --trace
   ```
3. **실패 이유까지 확인한다.** 의도한 assertion 실패여야 한다 — 컴파일 에러나 오타로 인한 실패는 RED가 아니다.

### GREEN — 통과하는 최소 구현

4. 테스트를 통과시키는 최소한의 코드만 작성한다. 다음 테스트가 요구할 것을 미리 구현하지 않는다.
5. 대상 테스트 통과 확인 후 **전체 스위트**를 돌려 회귀를 확인한다:
   ```powershell
   mix test
   ```

### REFACTOR — 정리

6. 중복 제거, 이름 정리, `mix format` 적용.
7. 전체 스위트 재실행으로 마무리. 실패 상태로 단계를 넘어가지 않는다.

버그픽스도 동일하다: **버그를 재현하는 실패 테스트부터** 작성하고, 그 테스트가 통과하면 수정 완료다.

## 2. 테스트 실행 규약 (상세 모드)

| 상황 | 명령 |
|---|---|
| TDD 루프 안 (특정 테스트) | `mix test path/to/test.exs:LINE --trace` |
| 기능 완료 시 (전체) | `mix test` |
| 실패 후 재시도 | `mix test --failed --trace` |
| 변경 영향만 빠르게 | `mix test --stale` |
| 순서 의존성 의심 | `mix test --seed 0` 과 기본(랜덤 seed) 비교 |
| 커버리지 확인 | `mix test --cover` |
| 마일스톤 마감 | `mix test --cover; mix format --check-formatted; mix dialyzer` (dialyzer는 도입 후) |

- `--trace`: 테스트별 이름·소요시간을 한 줄씩 출력 (동기 실행되므로 전체 스위트보다는 대상 파일에 사용).
- 결과 보고 시 통과/실패 개수와 실패 테스트의 assertion 출력을 그대로 인용한다. "테스트 통과했습니다" 한 줄로 끝내지 않는다.

## 3. ExUnit 작성 규칙

### 구조

- 테스트 파일은 소스 모듈과 1:1 대응: `lib/el_graph/checkpointer/ets.ex` → `test/el_graph/checkpointer/ets_test.exs`
- `describe` 블록 = 기능 단위(스펙 조항 단위). 테스트 이름은 **행동을 서술**한다:
  ```elixir
  describe "pending writes (SPEC §3.5)" do
    test "resuming after a partial parallel failure skips completed nodes" do
  ```

### 필수 규칙

1. **모든 테스트는 `async: true`.** `async: false`가 필요해 보이면 전역 상태 결합이 있다는 신호다 — 테스트가 아니라 설계를 고친다 (인스턴스별 ETS 테이블, 인자 주입, Mox 명시적 allowance).
2. **assertion은 패턴 매칭으로.** 길이+인덱스 조합 금지:
   ```elixir
   # 금지
   assert length(events) == 2
   assert Enum.at(events, 0).node == :a

   # 올바름 — 길이와 내용을 한 번에 검증
   assert [%{node: :a}, %{node: :b}] = events
   ```
   타입만 보는 `assert is_map(x)`도 금지 — 형태와 내용을 함께 매칭한다.
3. **공개 API만 테스트한다.** private 함수, 내부 구조체 레이아웃을 테스트하지 않는다. 리팩터링이 테스트를 깨면 구현을 테스트한 것이다.
4. **동기화에 `Process.sleep` 금지.** 메시지 기반 동기화(`assert_receive` 타임아웃)를 사용한다.
5. 에러는 `assert_raise(모듈, ~r/메시지 일부/, fn)` 으로 메시지까지 검증. 결과 튜플은 패턴 매칭: `assert {:error, {:write_conflict, :x, [:x1, :x2]}} = ...`
6. 파일시스템이 필요하면 `@tag :tmp_dir` (테스트별 격리 디렉터리, async 안전).

## 4. ElGraph 특화 규약

### 노드 정의

테스트 노드는 **`ElGraph.TestNodes` 모듈의 원격 캡처/MFA**로 작성한다 (`test/el_graph_test.exs` 상단). 익명 함수 노드는 compile 경고를 유발하며, MFA 사용은 durable 그래프 계약(SPEC §3.2)의 도그푸딩이다. 익명 함수가 정당한 경우는 "익명 함수도 동작한다/경고한다"를 검증하는 테스트뿐이다.

### 스트리밍/이벤트 검증

테스트 프로세스를 sink로 등록하고 메시지를 단언한다:

```elixir
{:ok, _} = ElGraph.invoke(graph, %{}, event_sink: self(), thread_id: "t1")
assert_receive {:el_graph_event, %{node: :a, event: {:token, "hi"}}}
```

### Telemetry 검증

telemetry 1.2+에 내장된 테스트 헬퍼를 사용한다 (핸들러 수동 attach/detach 금지):

```elixir
ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :node, :stop]])
{:ok, _} = ElGraph.invoke(graph, %{})
assert_receive {[:el_graph, :node, :stop], ^ref, %{duration: _}, %{node: :a}}
```

### 체크포인터 테스트 (M1 잔여 작업 시)

- 테스트마다 독립 인스턴스(setup에서 `start_supervised!` + 테이블 참조 전달). 이름 있는 싱글턴 금지.
- behaviour 적합성 테스트는 공유 모듈로 작성해 ETS/향후 DB 어댑터에 재사용한다:
  ```elixir
  # test/support/checkpointer_contract.ex — 모든 어댑터가 통과해야 하는 계약
  ```
- 재개 시나리오는 반드시 포함: 정상 재개, 부분 실패 후 pending writes 재개, 버전 필드 존재.

### LLM/외부 의존 (M2부터)

- behaviour(`ElGraph.LLM` 등)에 Mox로 mock을 생성하고 **명시적 allowance**로 async 유지.
- 실제 API를 때리는 테스트는 `@tag :integration`으로 분리하고 기본 실행에서 제외 (`test_helper.exs`에서 `ExUnit.configure(exclude: [:integration])`).

## 5. doctest

공개 API의 `@doc` 예제는 가능한 한 doctest로 실행 가능하게 작성하고, 테스트 모듈에 `doctest ElGraph` 를 선언한다. 문서가 거짓말하는 것을 컴파일 타임에 방지한다.

## 6. 금지 목록 (리뷰에서 즉시 반려)

- `async: false`
- `Process.sleep`로 타이밍 동기화
- `assert length(...) == n` + `Enum.at` 조합
- private 함수 직접 호출 테스트
- 테스트 없는 lib/ 변경 커밋
- RED 확인 없이 작성된 테스트 (통과하는 테스트를 먼저 쓰면 무엇을 검증하는지 보장 못 함)
- 삭제해도 테스트가 통과하는 코드 (tautological test)
