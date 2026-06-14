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

  @doc """
  데이터셋을 평가하고 요약을 반환한다.

  옵션:
    * `:score` — 스코어러 교체 (기본은 `:expect` 부분집합 검사).
    * `:max_concurrency` — 동시 평가 케이스 수 (기본 1 = 순차). `>1`이면 `Task.async_stream`으로
      병렬 채점하되 결과는 데이터셋 순서를 유지한다. 한 케이스가 크래시·타임아웃해도 실패로
      채점될 뿐 전체 실행을 멈추지 않는다.

  요약 맵: `%{total, passed, pass_rate, metrics, results}`. `:metrics`는 케이스별 `:score`에 대한
  집계 `%{pass_rate, mean_score, min_score, max_score, median_score}`다.
  """
  @spec run(ElGraph.Graph.t(), [case_spec()], keyword()) :: map()
  def run(graph, cases, opts \\ []) do
    score = Keyword.get(opts, :score, &default_score/2)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)

    results = eval_cases(graph, cases, score, max_concurrency)

    total = length(results)
    passed = Enum.count(results, & &1.pass)
    pass_rate = if(total == 0, do: 0.0, else: passed / total)

    %{
      total: total,
      passed: passed,
      pass_rate: pass_rate,
      metrics: metrics(results, pass_rate),
      results: results
    }
  end

  defp eval_cases(graph, cases, score, max_concurrency) when max_concurrency <= 1 do
    Enum.map(cases, &eval_case(graph, &1, score))
  end

  defp eval_cases(graph, cases, score, max_concurrency) do
    cases
    |> Task.async_stream(&eval_case(graph, &1, score),
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.zip(cases)
    |> Enum.map(fn
      {{:ok, result}, _case} -> result
      # 케이스 Task가 통째로 죽거나(타임아웃 포함) 잡히지 않은 exit이면 실패로 기록한다.
      {{:exit, reason}, c} -> failed_case(c, {:error, {:exit, reason}})
    end)
  end

  defp eval_case(graph, c, score) do
    result = safe_invoke(graph, c.input)
    verdict = score.(result, c)
    pass = verdict.pass

    base = %{
      input: c.input,
      result: result,
      pass: pass,
      score: Map.get(verdict, :score, if(pass, do: 1.0, else: 0.0))
    }

    with_id(base, c)
  end

  defp failed_case(c, result) do
    %{input: Map.get(c, :input), result: result, pass: false, score: 0.0}
    |> with_id(c)
  end

  defp with_id(result, %{id: id}), do: Map.put(result, :id, id)
  defp with_id(result, _case), do: result

  defp metrics([], pass_rate) do
    %{pass_rate: pass_rate, mean_score: 0.0, min_score: 0.0, max_score: 0.0, median_score: 0.0}
  end

  defp metrics(results, pass_rate) do
    scores = Enum.map(results, & &1.score)

    %{
      pass_rate: pass_rate,
      mean_score: Enum.sum(scores) / length(scores),
      min_score: Enum.min(scores),
      max_score: Enum.max(scores),
      median_score: median(scores)
    }
  end

  defp median(scores) do
    sorted = Enum.sort(scores)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
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

  @doc """
  JSONL 데이터셋을 로드한다 — 한 줄당 JSON 객체 하나, 빈 줄은 건너뛴다.

  최상위 `"input"`/`"expect"` 키를 atom 키(`:input`/`:expect`)로 바꾸고, 그 안쪽 맵의
  키도 atom으로 변환한다(`String.to_atom`). 따라서 로드된 케이스는 `run/3`의 기본 스코어러와
  바로 호환된다 — 그래프 상태 키(atom)와 일치. 신뢰된 데이터셋 전용이다(`String.to_atom`은
  atom 테이블에 쌓인다).
  """
  @spec load_jsonl(String.t()) :: [map()]
  def load_jsonl(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      line |> Jason.decode!() |> normalize_case()
    end)
  end

  defp normalize_case(decoded) do
    decoded
    |> Enum.into(%{}, fn
      {"input", v} -> {:input, atomize(v)}
      {"expect", v} -> {:expect, atomize(v)}
      {k, v} -> {k, v}
    end)
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp atomize(other), do: other

  @doc """
  베이스라인 요약과 후보 요약을 비교해 회귀/개선을 가려낸다.

  케이스는 `:id`가 있으면 id로, 없으면 인덱스로 매칭한다. 회귀는 베이스라인에서 통과했지만
  후보에서 실패한 케이스, 개선은 그 반대다. 반환: `%{pass_rate_delta, regressions, improvements}`.
  """
  @spec compare(map(), map()) :: map()
  def compare(baseline, candidate) do
    base_by_key = index_by_key(baseline.results)
    cand_by_key = index_by_key(candidate.results)

    keys = Map.keys(base_by_key) ++ (Map.keys(cand_by_key) -- Map.keys(base_by_key))

    {regressions, improvements} =
      Enum.reduce(keys, {[], []}, fn key, {regs, imps} ->
        base_pass = base_by_key |> Map.get(key, %{}) |> Map.get(:pass, false)
        cand_pass = cand_by_key |> Map.get(key, %{}) |> Map.get(:pass, false)

        cond do
          base_pass and not cand_pass -> {[key | regs], imps}
          not base_pass and cand_pass -> {regs, [key | imps]}
          true -> {regs, imps}
        end
      end)

    %{
      pass_rate_delta: candidate.pass_rate - baseline.pass_rate,
      regressions: Enum.reverse(regressions),
      improvements: Enum.reverse(improvements)
    }
  end

  # :id가 있으면 id로, 없으면 인덱스로 케이스를 식별한다.
  defp index_by_key(results) do
    results
    |> Enum.with_index()
    |> Map.new(fn {result, index} -> {Map.get(result, :id, index), result} end)
  end

  @doc """
  체크포인트 재생(time-travel) 평가.

  thread의 `step` 체크포인트를 가져와 각 시나리오마다 분기(fork)·재실행하고 채점한다.
  시나리오의 `:resume` 맵은 분기 시작 상태에 병합돼 "만약 이 step에서 상태가 달랐다면"을
  결정적으로 재현한다. 각 시나리오는 새 `thread_id`로 돌아 원본 thread는 보존된다.
  실행은 공개 API(`ElGraph.Executor.resume_from/3`, 체크포인터 `get/3`)만 쓴다.

  시나리오 맵은 `:resume` 외에 스코어러 필드(`:expect` 등)를 갖는다. 반환은 `run/3`와 같은
  요약(`%{total, passed, pass_rate, metrics, results}`)이다.
  """
  @spec replay_eval(
          ElGraph.Graph.t(),
          {module(), term()},
          String.t(),
          non_neg_integer(),
          [map()],
          keyword()
        ) :: map()
  def replay_eval(graph, {cp_mod, cp_config}, thread_id, step, scenarios, opts \\ []) do
    score = Keyword.get(opts, :score, &default_score/2)

    results =
      case cp_mod.get(cp_config, thread_id, step) do
        {:ok, checkpoint} ->
          Enum.map(scenarios, &replay_scenario(graph, checkpoint, &1, score))

        :not_found ->
          Enum.map(scenarios, &failed_case(&1, {:error, {:no_checkpoint, thread_id, step}}))
      end

    total = length(results)
    passed = Enum.count(results, & &1.pass)
    pass_rate = if(total == 0, do: 0.0, else: passed / total)

    %{
      total: total,
      passed: passed,
      pass_rate: pass_rate,
      metrics: metrics(results, pass_rate),
      results: results
    }
  end

  defp replay_scenario(graph, checkpoint, scenario, score) do
    resume = Map.get(scenario, :resume, %{})

    branch = %{
      checkpoint
      | state: Map.merge(checkpoint.state, resume),
        thread_id: fork_thread_id()
    }

    result =
      try do
        ElGraph.Executor.resume_from(graph, branch,
          thread_id: branch.thread_id,
          checkpointer: nil
        )
      rescue
        e -> {:error, {:raised, e}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    verdict = score.(result, scenario)
    pass = verdict.pass

    base = %{
      input: resume,
      result: result,
      pass: pass,
      score: Map.get(verdict, :score, if(pass, do: 1.0, else: 0.0))
    }

    with_id(base, scenario)
  end

  defp fork_thread_id, do: "replay-" <> Integer.to_string(System.unique_integer([:positive]))

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
