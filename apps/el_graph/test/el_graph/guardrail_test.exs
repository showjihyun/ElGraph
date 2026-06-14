defmodule ElGraph.GuardrailTest do
  use ExUnit.Case, async: true

  alias ElGraph.Guardrail

  describe "check/3 — sequential guards" do
    test "no guards passes the value through" do
      assert {:ok, "hi"} = Guardrail.check([], "hi")
    end

    test "deny/2 blocks a matching value" do
      guards = [Guardrail.deny(~r/password/i, :secret_leak)]
      assert {:blocked, :secret_leak} = Guardrail.check(guards, "my PASSWORD is 123")
      assert {:ok, "hello"} = Guardrail.check(guards, "hello")
    end

    test "max_length/1 blocks overly long input" do
      guards = [Guardrail.max_length(5)]
      assert {:blocked, {:too_long, 5}} = Guardrail.check(guards, "toolong")
      assert {:ok, "ok"} = Guardrail.check(guards, "ok")
    end

    test "redact/2 transforms the value and continues" do
      guards = [Guardrail.redact(~r/\d{3}-\d{4}/, "[REDACTED]")]
      assert {:ok, "call [REDACTED] now"} = Guardrail.check(guards, "call 555-1234 now")
    end

    test "guards apply in order: redact then deny sees the transformed value" do
      guards = [
        Guardrail.redact(~r/secret/, "***"),
        Guardrail.deny(~r/secret/, :still_secret)
      ]

      assert {:ok, "the *** is safe"} = Guardrail.check(guards, "the secret is safe")
    end

    test "a blocking guard short-circuits later guards" do
      guards = [Guardrail.deny(~r/bad/, :blocked), Guardrail.redact(~r/bad/, "x")]
      assert {:blocked, :blocked} = Guardrail.check(guards, "bad input")
    end
  end

  describe "authorize_tool/1 — tool authorization" do
    test "allows a permitted tool and blocks others" do
      guard = Guardrail.authorize_tool(["web_search", "calculator"])
      assert {:ok, "web_search"} = Guardrail.check([guard], "web_search")
      assert {:blocked, {:unauthorized_tool, "shell"}} = Guardrail.check([guard], "shell")
    end
  end
end
