defmodule ElGraph.EvalTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Eval, LLM}
  alias ElGraph.Test.ScriptedLLM

  defmodule Doubler do
    def run(%{n: n}, _ctx), do: %{n: n * 2}
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
  end
end
