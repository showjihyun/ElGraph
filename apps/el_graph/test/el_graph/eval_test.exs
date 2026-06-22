defmodule ElGraph.EvalTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Eval, LLM}
  alias ElGraph.Test.ScriptedLLM

  defmodule Doubler do
    def run(%{n: n}, _ctx), do: %{n: n * 2}
  end

  # 판정 LLM이 비-{:ok}를 돌려줄 때 llm_judge가 크래시 없이 실패로 채점하는지 검증용.
  defmodule ErrorLLM do
    def chat(_config, _messages, _opts), do: {:error, :unavailable}
  end

  defp graph do
    ElGraph.new()
    |> ElGraph.state(:n)
    |> ElGraph.add_node(:double, &Doubler.run/2)
    |> ElGraph.compile(entry: :double)
  end

  describe "run/3 — dataset evaluation" do
    test "scores cases against :expect with the default scorer" do
      cases = [
        %{input: %{n: 2}, expect: %{n: 4}},
        %{input: %{n: 5}, expect: %{n: 10}},
        %{input: %{n: 3}, expect: %{n: 999}}
      ]

      summary = Eval.run(graph(), cases)

      assert %{total: 3, passed: 2, pass_rate: rate, results: results} = summary
      assert_in_delta rate, 0.6667, 0.001
      assert [%{pass: true}, %{pass: true}, %{pass: false}] = results
    end

    test "supports a custom scorer" do
      cases = [%{input: %{n: 2}}]
      score = fn {:ok, %{n: n}}, _case -> %{pass: n > 0, score: n / 1.0} end

      assert %{passed: 1, results: [%{pass: true, score: 4.0}]} =
               Eval.run(graph(), cases, score: score)
    end

    test "a crashing/error run scores as a failure, not an exception" do
      cases = [%{input: %{n: 1}, expect: %{n: 2}}, %{input: %{n: 1}, expect: %{missing: :x}}]
      summary = Eval.run(graph(), cases)
      assert %{total: 2, passed: 1} = summary
    end

    test "the default scorer fails a case that has no :expect (fallback clause)" do
      assert %{passed: 0, results: [%{pass: false}]} = Eval.run(graph(), [%{input: %{n: 2}}])
    end
  end

  describe "run/3 — aggregate metrics" do
    test "computes pass_rate/mean/min/max/median over per-case scores" do
      # Doubler doubles n, so results are 4, 8, 12; scores = result/20 = 0.2, 0.4, 0.6.
      cases = [%{input: %{n: 2}}, %{input: %{n: 4}}, %{input: %{n: 6}}]
      score = fn {:ok, %{n: n}}, _case -> %{pass: n >= 8, score: n / 20.0} end

      summary = Eval.run(graph(), cases, score: score)

      assert %{
               metrics: %{
                 pass_rate: pass_rate,
                 mean_score: mean,
                 min_score: 0.2,
                 max_score: 0.6,
                 median_score: 0.4
               }
             } = summary

      # results 8 and 12 pass (>=8), 4 fails -> 2/3
      assert_in_delta pass_rate, 0.6667, 0.001
      assert_in_delta mean, 0.4, 0.001
    end

    test "metrics on an empty dataset are zeroed, not crashing" do
      assert %{
               metrics: %{
                 pass_rate: +0.0,
                 mean_score: +0.0,
                 min_score: +0.0,
                 max_score: +0.0,
                 median_score: +0.0
               }
             } =
               Eval.run(graph(), [])
    end

    test "median over an even number of scores averages the two middle values" do
      # Doubler doubles n; score = n/10 → scores 0.2, 0.4, 0.6, 0.8; median = (0.4+0.6)/2.
      cases = for n <- 1..4, do: %{input: %{n: n}}
      score = fn {:ok, %{n: n}}, _case -> %{pass: true, score: n / 10.0} end

      assert %{metrics: %{median_score: median}} = Eval.run(graph(), cases, score: score)
      assert_in_delta median, 0.5, 0.001
    end
  end

  describe "run/3 — parallel evaluation" do
    test "max_concurrency > 1 yields the same ordered results as sequential" do
      cases = for n <- 1..8, do: %{input: %{n: n}, expect: %{n: n * 2}}

      seq = Eval.run(graph(), cases, max_concurrency: 1)
      par = Eval.run(graph(), cases, max_concurrency: 4)

      assert seq.results == par.results
      assert par.total == 8
      assert par.passed == 8
    end

    test "a crash in one parallel case scores as failure without killing the run" do
      cases = [
        %{input: %{n: 2}, expect: %{n: 4}},
        # missing :n key -> Doubler.run/2 has no clause -> crash, scored as fail
        %{input: %{}, expect: %{n: 0}},
        %{input: %{n: 5}, expect: %{n: 10}}
      ]

      summary = Eval.run(graph(), cases, max_concurrency: 4)

      assert %{total: 3, passed: 2, results: [%{pass: true}, %{pass: false}, %{pass: true}]} =
               summary
    end
  end

  describe "load_jsonl/1" do
    test "loads a .jsonl dataset and runs it end-to-end through a graph" do
      path = Path.join([__DIR__, "..", "fixtures", "eval_dataset.jsonl"])
      cases = Eval.load_jsonl(path)

      assert [
               %{input: %{n: 2}, expect: %{n: 4}},
               %{input: %{n: 5}, expect: %{n: 10}},
               %{input: %{n: 3}, expect: %{n: 999}}
             ] = cases

      summary = Eval.run(graph(), cases)
      assert %{total: 3, passed: 2} = summary
    end
  end

  describe "compare/2 — baseline regression comparison" do
    test "detects regressions and improvements by index" do
      baseline = %{
        pass_rate: 0.5,
        results: [%{pass: true}, %{pass: false}, %{pass: true}, %{pass: false}]
      }

      candidate = %{
        pass_rate: 0.5,
        results: [%{pass: false}, %{pass: true}, %{pass: true}, %{pass: false}]
      }

      assert %{pass_rate_delta: +0.0, regressions: [0], improvements: [1]} =
               Eval.compare(baseline, candidate)
    end

    test "matches by case :id when present" do
      baseline = %{
        pass_rate: 1.0,
        results: [%{id: "a", pass: true}, %{id: "b", pass: true}]
      }

      candidate = %{
        pass_rate: 0.5,
        results: [%{id: "b", pass: true}, %{id: "a", pass: false}]
      }

      assert %{pass_rate_delta: -0.5, regressions: ["a"], improvements: []} =
               Eval.compare(baseline, candidate)
    end
  end

  describe "replay_eval/6 — checkpoint-replay (time-travel) evaluation" do
    defmodule Adder do
      # step 0: add a; step 1: add b
      def add_a(%{sum: sum}, _ctx), do: %{sum: sum + 10}
      def add_b(%{sum: sum}, _ctx), do: %{sum: sum + 100}
    end

    defp chain_graph do
      ElGraph.new()
      |> ElGraph.state(:sum, default: 0)
      |> ElGraph.add_node(:a, &Adder.add_a/2)
      |> ElGraph.add_node(:b, &Adder.add_b/2)
      |> ElGraph.add_edge(:a, :b)
      |> ElGraph.compile(entry: :a)
    end

    test "replays from an intermediate checkpoint with different branch states" do
      {:ok, cp} = ElGraph.Checkpointer.ETS.start_link()
      config = ElGraph.Checkpointer.ETS.config(cp)
      cp_spec = {ElGraph.Checkpointer.ETS, config}

      thread = "original"

      # Original run: sum 0 -> +10 (step1) -> +110 (step2 end). Produces checkpoints.
      {:ok, %{sum: 110}} =
        ElGraph.invoke(chain_graph(), %{}, checkpointer: cp_spec, thread_id: thread)

      # At step 1, state is %{sum: 10}, next is [:b]. Branch the :sum before running :b.
      scenarios = [
        %{resume: %{sum: 1000}, expect: %{sum: 1100}},
        %{resume: %{sum: 5}, expect: %{sum: 999}}
      ]

      summary = Eval.replay_eval(chain_graph(), cp_spec, thread, 1, scenarios)

      assert %{total: 2, passed: 1, results: [%{pass: true}, %{pass: false}]} = summary
      # original thread is preserved
      assert {:ok, %ElGraph.Checkpoint{state: %{sum: 110}}} =
               ElGraph.Checkpointer.ETS.get(config, thread, :latest)
    end

    test "a missing checkpoint scores every scenario as a failure" do
      {:ok, cp} = ElGraph.Checkpointer.ETS.start_link()
      cp_spec = {ElGraph.Checkpointer.ETS, ElGraph.Checkpointer.ETS.config(cp)}

      scenarios = [
        %{resume: %{sum: 1}, expect: %{sum: 1}},
        %{resume: %{sum: 2}, expect: %{sum: 2}}
      ]

      summary = Eval.replay_eval(chain_graph(), cp_spec, "nope", 99, scenarios)

      assert %{total: 2, passed: 0, results: results} = summary

      assert Enum.all?(
               results,
               &match?(%{pass: false, result: {:error, {:no_checkpoint, "nope", 99}}}, &1)
             )
    end
  end

  describe "llm_judge/2 — LLM-as-judge scorer" do
    test "passes when the judge replies PASS" do
      {:ok, llm} = ScriptedLLM.start_link([LLM.assistant("PASS")])
      score = Eval.llm_judge({ScriptedLLM, llm}, "Is the answer correct?")

      cases = [%{input: %{n: 2}, expect: %{n: 4}}]
      assert %{passed: 1, results: [%{pass: true}]} = Eval.run(graph(), cases, score: score)
    end

    test "fails when the judge replies FAIL" do
      {:ok, llm} = ScriptedLLM.start_link([LLM.assistant("FAIL: wrong")])
      score = Eval.llm_judge({ScriptedLLM, llm}, "Is the answer correct?")

      cases = [%{input: %{n: 2}, expect: %{n: 5}}]
      assert %{passed: 0, results: [%{pass: false}]} = Eval.run(graph(), cases, score: score)
    end

    test "fails the case (no crash) when the judge LLM returns a non-:ok result" do
      score = Eval.llm_judge({ErrorLLM, :cfg}, "Is the answer correct?")
      cases = [%{input: %{n: 2}, expect: %{n: 4}}]

      assert %{passed: 0, results: [%{pass: false}]} = Eval.run(graph(), cases, score: score)
    end
  end
end
