defmodule ElGraph.CompileError do
  @moduledoc "그래프 정의가 유효하지 않을 때 `ElGraph.compile/2`에서 발생한다."
  defexception [:message]
end
