defmodule ElGraph.Memory do
  @moduledoc """
  스코프 기반 장기 기억 (트렌드 보고서 Tier 2.6).

  2026 트렌드: 프로덕션 #1 장애가 *memory hallucination*(자기 히스토리에서 모순·낡은
  사실 회수). 이를 완화하려고 기억을 3-스코프로 나누고 **시점 진실(latest-wins)**을 적용한다.

    * episodic  — 시간순 이벤트 로그 (무엇이 일어났나)
    * semantic  — subject별 사실, 최신이 과거를 대체 (지금 참인 것)
    * procedural — 학습된 규칙/선호

  `ElGraph.Store` 어댑터(KV) 위의 순수 계층이다 — Store behaviour만 사용하므로 ETS/DB 등
  어느 어댑터로든 동작한다. namespace로 주체(사용자 등)를 분리한다.

      mem = ElGraph.Memory.new({ElGraph.Store.ETS, config})
      ElGraph.Memory.set_fact(mem, ["users", "u1"], "plan", "pro")
      ElGraph.Memory.get_fact(mem, ["users", "u1"], "plan")  #=> {:ok, "pro"}
  """

  @enforce_keys [:store]
  defstruct [:store]

  @type t :: %__MODULE__{store: {module(), ElGraph.Store.config()}}
  @type namespace :: [String.t()]

  @doc "Store 어댑터(`{module, config}`)를 감싼 Memory를 만든다."
  @spec new({module(), ElGraph.Store.config()}) :: t()
  def new({mod, _config} = store) when is_atom(mod), do: %__MODULE__{store: store}

  ## episodic — 시간순 로그

  @doc "에피소드(이벤트)를 기록한다. `:at`(정렬 키, 기본 단조 증가)."
  @spec record_episode(t(), namespace(), term(), keyword()) :: :ok
  def record_episode(%__MODULE__{} = mem, ns, event, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &mono/0)
    put(mem, scope(ns, "episodic"), key(at), %{value: event, at: at})
  end

  @doc "에피소드를 최신순으로 회수한다. `:limit`."
  @spec recall_episodes(t(), namespace(), keyword()) :: [term()]
  def recall_episodes(%__MODULE__{} = mem, ns, opts \\ []) do
    mem
    |> list(scope(ns, "episodic"))
    |> Enum.sort_by(& &1.at, :desc)
    |> maybe_take(Keyword.get(opts, :limit))
    |> Enum.map(& &1.value)
  end

  ## semantic — subject별 최신 사실

  @doc "사실을 기록한다 — 같은 subject의 과거 값을 대체한다(시점 진실)."
  @spec set_fact(t(), namespace(), String.t(), term(), keyword()) :: :ok
  def set_fact(%__MODULE__{} = mem, ns, subject, value, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &mono/0)
    put(mem, scope(ns, "semantic"), subject, %{value: value, at: at})
  end

  @doc "subject의 현재 참 값을 회수한다."
  @spec get_fact(t(), namespace(), String.t()) :: {:ok, term()} | :unknown
  def get_fact(%__MODULE__{store: {mod, config}}, ns, subject) do
    case mod.get(config, scope(ns, "semantic"), subject) do
      {:ok, %{value: value}} -> {:ok, value}
      :not_found -> :unknown
    end
  end

  @doc "현재 참인 모든 사실을 `%{subject => value}`로 회수한다."
  @spec recall_facts(t(), namespace()) :: %{String.t() => term()}
  def recall_facts(%__MODULE__{store: {mod, config}}, ns) do
    config
    |> mod.list(scope(ns, "semantic"))
    |> Map.new(fn {subject, %{value: value}} -> {subject, value} end)
  end

  ## procedural — 규칙

  @doc "규칙/선호를 학습한다."
  @spec learn(t(), namespace(), String.t(), term()) :: :ok
  def learn(%__MODULE__{} = mem, ns, name, rule),
    do: put(mem, scope(ns, "procedural"), name, %{value: rule})

  @doc "학습된 규칙을 `%{name => rule}`로 회수한다."
  @spec recall_rules(t(), namespace()) :: %{String.t() => term()}
  def recall_rules(%__MODULE__{store: {mod, config}}, ns) do
    config
    |> mod.list(scope(ns, "procedural"))
    |> Map.new(fn {name, %{value: rule}} -> {name, rule} end)
  end

  ## 내부

  defp put(%__MODULE__{store: {mod, config}}, ns, key, value), do: mod.put(config, ns, key, value)

  defp list(%__MODULE__{store: {mod, config}}, ns) do
    config |> mod.list(ns) |> Enum.map(fn {_key, entry} -> entry end)
  end

  defp scope(ns, name), do: ns ++ [name]

  # 정렬 가능한 고정폭 문자열 키 (정수 at 기준).
  defp key(at), do: at |> Integer.to_string() |> String.pad_leading(20, "0")

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, limit), do: Enum.take(list, limit)

  defp mono, do: System.unique_integer([:monotonic, :positive])
end
