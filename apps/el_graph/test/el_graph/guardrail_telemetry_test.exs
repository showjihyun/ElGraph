defmodule ElGraph.GuardrailTelemetryTest do
  # 전역 `[:el_graph, :guardrail, :block]` telemetry를 관측한다. "차단 시 미방출"은
  # refute_receive를 쓰므로 다른 async 테스트의 차단 emit에 오염될 수 있다 → async: false로
  # sync 단계에서 단독 실행해 격리한다.
  use ExUnit.Case, async: false

  alias ElGraph.Guardrail

  test "emits a block event on a blocked check" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :guardrail, :block]])

    assert {:blocked, :secret_leak} =
             Guardrail.check([Guardrail.deny(~r/secret/, :secret_leak)], "the secret")

    assert_receive {[:el_graph, :guardrail, :block], ^ref, %{count: 1}, %{reason: :secret_leak}}
  end

  test "does not emit on a passing check" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :guardrail, :block]])

    assert {:ok, "fine"} = Guardrail.check([Guardrail.deny(~r/secret/, :x)], "fine")

    refute_receive {[:el_graph, :guardrail, :block], ^ref, _, _}, 50
  end
end
