defmodule ElGraph.GuardrailTest do
  use ExUnit.Case, async: true

  alias ElGraph.Guardrail
  alias ElGraph.Guardrail.PII

  doctest ElGraph.Guardrail

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

  describe "PII pattern library" do
    test "patterns/0 exposes the expected keys as compiled regexes" do
      patterns = PII.patterns()

      for key <- [:email, :phone, :credit_card, :ssn, :rrn, :ipv4] do
        assert %Regex{} = Map.fetch!(patterns, key)
      end
    end

    test "pattern/1 fetches a single compiled regex" do
      assert %Regex{} = PII.pattern(:email)
    end

    test "email pattern matches an email" do
      assert Regex.match?(PII.pattern(:email), "reach me at jane.doe@example.com please")
    end

    test "Korean RRN matches :rrn" do
      assert Regex.match?(PII.pattern(:rrn), "주민번호 900101-1234567 입니다")
    end

    test "ssn pattern matches US SSN" do
      assert Regex.match?(PII.pattern(:ssn), "SSN 123-45-6789")
    end

    test "ipv4 pattern matches an address" do
      assert Regex.match?(PII.pattern(:ipv4), "from 192.168.0.1 today")
    end
  end

  describe "redact_pii/2" do
    test "redacts email and phone in a string" do
      guards = [Guardrail.redact_pii([:email, :phone])]
      input = "email jane@example.com or call 555-123-4567"
      assert {:ok, redacted} = Guardrail.check(guards, input)
      refute redacted =~ "jane@example.com"
      refute redacted =~ "555-123-4567"
      assert redacted =~ "[REDACTED]"
    end

    test ":all redacts every pattern type" do
      guards = [Guardrail.redact_pii(:all)]
      input = "mail a@b.com ssn 123-45-6789"
      assert {:ok, redacted} = Guardrail.check(guards, input)
      refute redacted =~ "a@b.com"
      refute redacted =~ "123-45-6789"
    end

    test "clean text passes through unchanged" do
      guards = [Guardrail.redact_pii(:all)]
      assert {:ok, "hello world"} = Guardrail.check(guards, "hello world")
    end
  end

  describe "deny_pii/1" do
    test "blocks on credit card" do
      guards = [Guardrail.deny_pii([:credit_card])]

      assert {:blocked, {:pii, :credit_card}} =
               Guardrail.check(guards, "card 4111 1111 1111 1111")
    end

    test "clean text passes" do
      guards = [Guardrail.deny_pii(:all)]
      assert {:ok, "just words"} = Guardrail.check(guards, "just words")
    end
  end

  describe "validate_schema/1" do
    test "passes a valid map and blocks an invalid one" do
      guard = Guardrail.validate_schema(answer: [type: :string, required: true])
      assert {:ok, %{answer: "hi"}} = Guardrail.check([guard], %{answer: "hi"})
      assert {:blocked, {:invalid_output, _reason}} = Guardrail.check([guard], %{})
    end

    test "passes a valid keyword list" do
      guard = Guardrail.validate_schema(answer: [type: :string, required: true])
      assert {:ok, [answer: "hi"]} = Guardrail.check([guard], answer: "hi")
    end

    test "accepts a pre-compiled NimbleOptions schema" do
      schema = NimbleOptions.new!(answer: [type: :string, required: true])
      guard = Guardrail.validate_schema(schema)
      assert {:ok, %{answer: "hi"}} = Guardrail.check([guard], %{answer: "hi"})
    end
  end

  # block telemetry 테스트는 전역 telemetry + refute_receive라 async 오염되어
  # `ElGraph.GuardrailTelemetryTest`(async: false)로 분리했다.

  describe "guard_value/4 — node integration" do
    test "redact updates the state field" do
      state = %{output: "email a@b.com"}
      guards = [Guardrail.redact_pii([:email])]
      assert {:ok, %{output: redacted}} = Guardrail.guard_value(state, :output, guards)
      refute redacted =~ "a@b.com"
    end

    test "deny returns {:blocked, reason}" do
      state = %{output: "card 4111 1111 1111 1111"}
      guards = [Guardrail.deny_pii([:credit_card])]
      assert {:blocked, {:pii, :credit_card}} = Guardrail.guard_value(state, :output, guards)
    end
  end
end
