defmodule ElGraph.Guardrail do
  @moduledoc """
  입출력 가드레일 / 정책 계층 (트렌드 보고서 Tier 3.9).

  성숙도와 함께 필수가 되는 안전장치 — LLM 입출력 검증(PII/비밀/길이)과 툴 인가를 조합
  가능한 가드로 표현한다. `max_steps`/`budget`(비용)의 자연스러운 확장이다.

  가드는 `(value, ctx) -> :ok | {:block, reason} | {:transform, new_value}` 함수다.
  `check/3`이 순서대로 적용한다 — transform은 값을 바꿔 다음 가드로 넘기고, block은 즉시
  중단한다. 노드 안에서 LLM 입력/출력이나 tool_call 이름에 적용한다.

      guards = [Guardrail.redact(~r/\\d{3}-\\d{4}/, "[REDACTED]"), Guardrail.max_length(4000)]
      case Guardrail.check(guards, user_input) do
        {:ok, safe} -> ...
        {:blocked, reason} -> ...
      end
  """

  @type guard :: (term(), map() -> :ok | {:block, term()} | {:transform, term()})

  alias ElGraph.Guardrail.PII

  @doc "가드를 순서대로 적용한다. 통과 시 `{:ok, value}`, 차단 시 `{:blocked, reason}`."
  @spec check([guard()], term(), map()) :: {:ok, term()} | {:blocked, term()}
  def check(guards, value, ctx \\ %{}) do
    result =
      Enum.reduce_while(guards, {:ok, value}, fn guard, {:ok, value} ->
        case guard.(value, ctx) do
          :ok -> {:cont, {:ok, value}}
          {:transform, new_value} -> {:cont, {:ok, new_value}}
          {:block, reason} -> {:halt, {:blocked, reason}}
        end
      end)

    case result do
      {:blocked, reason} ->
        :telemetry.execute([:el_graph, :guardrail, :block], %{count: 1}, %{reason: reason})

      {:ok, _} ->
        :ok
    end

    result
  end

  @doc "값이 패턴에 매치하면 차단한다 (PII/비밀 누출 등)."
  @spec deny(Regex.t(), term()) :: guard()
  def deny(%Regex{} = pattern, reason) do
    fn value, _ctx ->
      if is_binary(value) and Regex.match?(pattern, value), do: {:block, reason}, else: :ok
    end
  end

  @doc "패턴 매치 부분을 치환한다 (마스킹). 항상 통과하며 값만 바꾼다."
  @spec redact(Regex.t(), String.t()) :: guard()
  def redact(%Regex{} = pattern, replacement) do
    fn value, _ctx ->
      if is_binary(value), do: {:transform, Regex.replace(pattern, value, replacement)}, else: :ok
    end
  end

  @doc "문자열 길이가 `max`를 넘으면 차단한다."
  @spec max_length(pos_integer()) :: guard()
  def max_length(max) when is_integer(max) and max > 0 do
    fn value, _ctx ->
      if is_binary(value) and String.length(value) > max,
        do: {:block, {:too_long, max}},
        else: :ok
    end
  end

  @doc "값(툴 이름)이 허용 목록에 없으면 차단한다 — 툴 인가."
  @spec authorize_tool([String.t()]) :: guard()
  def authorize_tool(allowed) when is_list(allowed) do
    fn value, _ctx ->
      if value in allowed, do: :ok, else: {:block, {:unauthorized_tool, value}}
    end
  end

  @doc """
  요청한 PII 타입을 마스킹하는 가드를 반환한다. `:all`은 모든 패턴이다.
  치환 문자열 기본값은 `"[REDACTED]"`. 항상 통과하며 값만 바꾼다.
  """
  @spec redact_pii([atom()] | :all, String.t()) :: guard()
  def redact_pii(types, replacement \\ "[REDACTED]") do
    patterns = pii_patterns(types)

    fn value, _ctx ->
      if is_binary(value) do
        redacted =
          Enum.reduce(patterns, value, fn {_type, regex}, acc ->
            Regex.replace(regex, acc, replacement)
          end)

        {:transform, redacted}
      else
        :ok
      end
    end
  end

  @doc """
  요청한 PII 타입이 하나라도 있으면 `{:block, {:pii, type}}`로 차단한다. `:all`은 모든 패턴.
  """
  @spec deny_pii([atom()] | :all) :: guard()
  def deny_pii(types) do
    patterns = pii_patterns(types)

    fn value, _ctx ->
      if is_binary(value) do
        case Enum.find(patterns, fn {_type, regex} -> Regex.match?(regex, value) end) do
          {type, _regex} -> {:block, {:pii, type}}
          nil -> :ok
        end
      else
        :ok
      end
    end
  end

  @doc """
  값(keyword 또는 map)을 NimbleOptions 스키마로 검증한다. 유효하면 `:ok`,
  아니면 `{:block, {:invalid_output, reason}}`. keyword 스키마는 컴파일해서 받는다.
  """
  @spec validate_schema(NimbleOptions.t() | keyword()) :: guard()
  def validate_schema(%NimbleOptions{} = schema) do
    fn value, _ctx ->
      keyword = if is_map(value), do: Map.to_list(value), else: value

      case NimbleOptions.validate(keyword, schema) do
        {:ok, _validated} -> :ok
        {:error, %NimbleOptions.ValidationError{} = error} -> {:block, {:invalid_output, error}}
      end
    end
  end

  def validate_schema(schema) when is_list(schema) do
    validate_schema(NimbleOptions.new!(schema))
  end

  @doc """
  상태 맵의 `key` 필드를 가드로 검사한다. 통과 시 변환된 값을 다시 넣은 상태를
  `{:ok, state}`로, 차단 시 `{:blocked, reason}`을 반환한다 — 노드의 입출력 가딩 진입점.
  """
  @spec guard_value(map(), atom(), [guard()], keyword()) :: {:ok, map()} | {:blocked, term()}
  def guard_value(state, key, guards, opts \\ []) do
    ctx = Keyword.get(opts, :ctx, %{})

    case check(guards, Map.get(state, key), ctx) do
      {:ok, transformed} -> {:ok, Map.put(state, key, transformed)}
      {:blocked, reason} -> {:blocked, reason}
    end
  end

  defp pii_patterns(:all), do: PII.patterns()

  defp pii_patterns(types) when is_list(types),
    do: Map.new(types, fn type -> {type, PII.pattern(type)} end)
end
