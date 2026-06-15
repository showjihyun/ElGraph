# Dialyzer 무시 패턴. 외부(Ecto/Postgrex) 경고만 격리하고, 자체 모듈 경고는 코드로 고친다.
#
# 마이그레이션 생성 mix 태스크는 Mix.Task behaviour / Mix.Generator 함수를 참조하나, Mix는
# umbrella 공유 PLT에 적재되지 않아 callback_info_missing / unknown_function false-positive가
# 난다(함수는 실재하며 런타임 정상). 해당 파일의 두 경고 타입만 한정해 무시한다.
[
  {"lib/mix/tasks/el_graph.ecto.gen.migration.ex", :callback_info_missing},
  {"lib/mix/tasks/el_graph.ecto.gen.migration.ex", :unknown_function}
]
