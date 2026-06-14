defmodule ElGraph.Demo.DocsSearch do
  @moduledoc """
  도그푸딩 툴: ElGraph 자체 문서(`docs/*.md`)에서 키워드를 검색한다.

  결과는 `"파일명:줄번호: 내용"` 형태 문자열 목록 (최대 20개).
  """

  use ElGraph.Action,
    name: "docs_search",
    description: "ElGraph 프로젝트 문서(docs/*.md)에서 키워드를 검색해 매칭되는 줄을 반환한다",
    schema: [
      query: [type: :string, required: true, doc: "검색 키워드 (대소문자 무시)"]
    ]

  @impl true
  def run(%{query: query}, _context) do
    # 도그푸딩 발견(2026-06-13): 전체 문자열 부분일치는 멀티워드 질의에서 0건 —
    # 단어별 매칭 + 겹친 단어 수 랭킹으로 교체.
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    results =
      ElGraph.Demo.docs_glob()
      |> Path.wildcard()
      |> Enum.flat_map(&scored_lines(&1, words))
      |> Enum.sort_by(fn {score, _line} -> -score end)
      |> Enum.take(20)
      |> Enum.map(fn {_score, line} -> line end)

    {:ok, %{results: results}}
  end

  defp scored_lines(path, words) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, no} ->
      downcased = String.downcase(line)
      score = Enum.count(words, &String.contains?(downcased, &1))

      if score > 0 do
        [{score, "#{Path.basename(path)}:#{no}: #{String.trim(line)}"}]
      else
        []
      end
    end)
  end
end
