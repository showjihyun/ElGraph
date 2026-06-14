defmodule ElGraph.Eval do
  @moduledoc """
  경량 평가 하네스 (트렌드 보고서 Tier 3.8).

  데이터셋의 각 케이스를 그래프에 invoke하고 스코어러로 채점한다. 풀 eval 프레임워크가
  아니라 ElGraph의 차별점(결정적 실행·체크포인트)을 활용한 회귀 평가 훅이다 — `ElGraph.invoke/3`
  공개 API 위의 순수 오케스트레이션이라 어떤 그래프에도 붙는다.

      cases = [%{input: %{n: 2}, expect: %{n: 4}}, ...]
      ElGraph.Eval.run(graph, cases)
      #=> %{total: ..., passed: ..., pass_rate: ..., results: [...]}

  스코어러는 `(invoke_result, case) -> %{pass: boolean, score: number}`. 기본은 `:expect`
  맵이 결과 상태의 부분집합인지 본다. LLM-judge는 `llm_judge/2`로 만든다.
  """

  alias ElGraph.LLM

  @type case_spec :: %{
          required(:input) => map(),
          optional(:expect) => map(),
          optional(any()) => any()
        }
  @type scorer :: (term(), case_spec() ->
                     %{required(:pass) => boolean(), optional(:score) => number()})

  @doc "데이터셋을 평가하고 요약을 반환한다. `opts[:score]`로 스코어러 교체."
  @spec run(ElGraph.Graph.t(), [case_spec()], keyword()) :: map()
  def run(graph, cases, opts \\ []) do
    score = Keyword.get(opts, :score, &default_score/2)

    results =
      Enum.map(cases, fn c ->
        result = safe_invoke(graph, c.input)
        verdict = score.(result, c)
        pass = verdict.pass

        %{
          input: c.input,
          result: result,
          pass: pass,
          score: Map.get(verdict, :score, if(pass, do: 1.0, else: 0.0))
        }
      end)

    total = length(results)
    passed = Enum.count(results, & &1.pass)

    %{
      total: total,
      passed: passed,
      pass_rate: if(total == 0, do: 0.0, else: passed / total),
      results: results
    }
  end

  @doc """
  LLM-as-judge 스코어러를 만든다. 판정 모델이 `PASS`로 시작하는 답을 내면 통과로 본다.
  """
  @spec llm_judge({module(), term()}, String.t()) :: scorer()
  def llm_judge({mod, config}, criteria) do
    fn result, case_spec ->
      prompt = judge_prompt(criteria, case_spec, result)

      case mod.chat(config, [LLM.user(prompt)], []) do
        {:ok, %{message: %{content: content}}} -> %{pass: passed?(content)}
        _error -> %{pass: false}
      end
    end
  end

  ## 내부

  defp safe_invoke(graph, input) do
    ElGraph.invoke(graph, input)
  rescue
    e -> {:error, {:raised, e}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp default_score({:ok, state}, %{expect: expect}) when is_map(expect) do
    %{pass: Enum.all?(expect, fn {k, v} -> Map.get(state, k) == v end)}
  end

  defp default_score(_result, _case), do: %{pass: false}

  defp passed?(content) when is_binary(content) do
    content |> String.trim() |> String.upcase() |> String.starts_with?("PASS")
  end

  defp passed?(_), do: false

  defp judge_prompt(criteria, case_spec, result) do
    """
    You are grading an agent's output. Criterion: #{criteria}

    Input: #{inspect(Map.get(case_spec, :input))}
    Expected (if any): #{inspect(Map.get(case_spec, :expect))}
    Actual result: #{inspect(result)}

    Reply with PASS or FAIL, optionally followed by a brief reason. Start with the verdict.
    """
  end
end
