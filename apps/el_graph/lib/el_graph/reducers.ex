defmodule ElGraph.Reducers do
  @moduledoc """
  내장 reducer 모음. `ElGraph.state/3`의 `:reducer` 옵션에 MFA로 지정한다.

      ElGraph.state(graph, :messages, default: [], reducer: {ElGraph.Reducers, :append, []})

  reducer 시그니처는 `(현재값, 새값) -> 병합값`.
  """

  @doc """
  리스트에 새 값(들)을 뒤에 추가한다. 새 값이 리스트가 아니면 단일 원소로 감싼다.

  `{:replace, list}` 마커는 추가 대신 채널을 통째로 치환한다 — 컨텍스트 압축
  (`ElGraph.Nodes.Summarize`)이 오래된 메시지를 줄일 때 쓴다.
  """
  @spec append(list(), term()) :: list()
  def append(_current, {:replace, list}) when is_list(list), do: list
  def append(current, new) when is_list(current), do: current ++ List.wrap(new)

  @doc """
  append 후 최근 `keep_last`개만 유지한다 — 컨텍스트 압축 1단계 (SPEC §3.1).

      ElGraph.state(graph, :messages, default: [], reducer: {ElGraph.Reducers, :append_trim, [100]})
  """
  @spec append_trim(list(), term(), pos_integer()) :: list()
  def append_trim(current, new, keep_last) when is_list(current) and keep_last > 0 do
    current |> append(new) |> Enum.take(-keep_last)
  end

  @doc "맵을 병합한다. 키 충돌 시 새 값이 이긴다."
  @spec merge(map(), map()) :: map()
  def merge(current, new) when is_map(current) and is_map(new), do: Map.merge(current, new)

  @doc "숫자를 누적 합산한다."
  @spec add(number(), number()) :: number()
  def add(current, new) when is_number(current) and is_number(new), do: current + new
end
