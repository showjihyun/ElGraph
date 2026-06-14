defmodule ElGraph.Memory.Embedder do
  @moduledoc """
  텍스트를 벡터로 변환하는 임베더 behaviour.

  `ElGraph.Memory.recall_relevant/4`가 시맨틱 회수(코사인 유사도 랭킹)에 사용한다.
  순수 함수 계약이므로 결정적 테스트 임베더, 외부 모델 어댑터 등 무엇으로든 구현할 수 있다.
  """

  @callback embed(text :: String.t()) :: [float()]
end
