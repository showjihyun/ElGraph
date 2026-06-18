# Dialyzer 무시 패턴. Phoenix/LiveView 매크로 생성 코드의 불가피한 경고만 격리하고,
# 자체 모듈 경고는 코드로 고친다.
#
# test/support/conn_case.ex(`use ExUnit.CaseTemplate`)는 ExUnit 내부 함수
# (ExUnit.Callbacks.__merge__/__noop__, ExUnit.CaseTemplate.__proxy__)를 참조하나,
# ExUnit는 test 환경 PLT에 적재되지 않아 unknown_function false-positive가 난다
# (함수는 실재하며 런타임 정상). MIX_ENV=test dialyzer에서만 발생.
[
  {"test/support/conn_case.ex", :unknown_function}
]
