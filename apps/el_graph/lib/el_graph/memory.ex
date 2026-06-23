defmodule ElGraph.Memory do
  @moduledoc """
  스코프 기반 장기 기억 (트렌드 보고서 Tier 2.6).

  2026 트렌드: 프로덕션 #1 장애가 *memory hallucination*(자기 히스토리에서 모순·낡은
  사실 회수). 이를 완화하려고 기억을 3-스코프로 나누고 **시점 진실(latest-wins)**을 적용한다.

    * episodic  — 시간순 이벤트 로그 (무엇이 일어났나)
    * semantic  — subject별 사실, 최신이 과거를 대체 (지금 참인 것)
    * procedural — 학습된 규칙/선호

  `ElGraph.Store` 어댑터(KV) 위의 순수 계층이다 — **오직 `ElGraph.Store` behaviour만**
  사용한다(`put/get/delete/list`). 따라서 ETS/Postgres 등 어느 Store 어댑터로든 동일하게
  동작하며 어댑터별 가정이 새지 않는다. namespace로 주체(사용자 등)를 분리한다.

      mem = ElGraph.Memory.new({ElGraph.Store.ETS, config})
      ElGraph.Memory.set_fact(mem, ["users", "u1"], "plan", "pro")
      ElGraph.Memory.get_fact(mem, ["users", "u1"], "plan")  #=> {:ok, "pro"}

  추가 기능:

    * `recall_relevant/4` — 임베더(`ElGraph.Memory.Embedder`) 기반 시맨틱 회수
      (코사인 유사도 랭킹).
    * `fact_history/3` — 사실이 어떻게 대체되어 왔는지 감사(시점 진실 + 출처).
    * `forget/4` — 사실/규칙 삭제.
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
  @spec record_episode(t(), namespace(), term(), keyword()) ::
          :ok | {:error, {:not_serializable, term()}}
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

  @typedoc """
  같은 subject에 새 값이 들어올 때의 충돌 해소 정책.

    * `:latest`  — 새 값이 과거를 대체(기본). 직전 값은 히스토리로.
    * `:reject`  — 기존 값을 유지하고 새 값을 버린다(write-once 사실). 히스토리 변화 없음.
    * `fun/2`    — `(기존값, 새값) -> 병합값`. 병합 결과를 현재 값으로 두고 직전 값은 히스토리로.
  """
  @type on_conflict :: :latest | :reject | (term(), term() -> term())

  @doc """
  사실을 기록한다 — 같은 subject의 과거 값을 대체한다(시점 진실).

  대체되는 직전 값은 `fact_history/3`로 감사할 수 있도록 subject별 히스토리에 보관한다.

  옵션:

    * `:at` — 정렬/시점 키(기본 단조 증가). `fact_at/4`의 비교 기준.
    * `:on_conflict` — 기존 값이 있을 때의 정책(`t:on_conflict/0`, 기본 `:latest`).
  """
  @spec set_fact(t(), namespace(), String.t(), term(), keyword()) ::
          :ok | {:error, {:not_serializable, term()}}
  def set_fact(%__MODULE__{store: {mod, config}} = mem, ns, subject, value, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &mono/0)
    on_conflict = Keyword.get(opts, :on_conflict, :latest)

    case mod.get(config, scope(ns, "semantic"), subject) do
      {:ok, prior} -> resolve_conflict(mem, ns, subject, prior, value, at, on_conflict)
      :not_found -> put(mem, scope(ns, "semantic"), subject, %{value: value, at: at})
    end
  end

  defp resolve_conflict(_mem, _ns, _subject, _prior, _value, _at, :reject), do: :ok

  defp resolve_conflict(mem, ns, subject, prior, value, at, :latest) do
    push_history(mem, ns, subject, prior)
    put(mem, scope(ns, "semantic"), subject, %{value: value, at: at})
  end

  defp resolve_conflict(mem, ns, subject, prior, value, at, merge) when is_function(merge, 2) do
    push_history(mem, ns, subject, prior)
    put(mem, scope(ns, "semantic"), subject, %{value: merge.(prior.value, value), at: at})
  end

  @doc "subject의 현재 참 값을 회수한다."
  @spec get_fact(t(), namespace(), String.t()) :: {:ok, term()} | :unknown
  def get_fact(%__MODULE__{store: {mod, config}}, ns, subject) do
    case mod.get(config, scope(ns, "semantic"), subject) do
      {:ok, %{value: value}} -> {:ok, value}
      :not_found -> :unknown
    end
  end

  @doc """
  주어진 시점 `at`에 참이었던 값을 회수한다(temporal 쿼리).

  현재 값과 `fact_history/3`의 과거 값을 합친 타임라인에서, `entry.at <= at`인 것 중
  가장 최근 값을 돌려준다. `at`이 가장 이른 값보다 앞서면 `:unknown`.
  비교는 `set_fact`의 `:at`과 동일 시계를 쓴다는 전제다.
  """
  @spec fact_at(t(), namespace(), String.t(), term()) :: {:ok, term()} | :unknown
  def fact_at(%__MODULE__{} = mem, ns, subject, at) do
    case Enum.find(timeline(mem, ns, subject), &(&1.at <= at)) do
      %{value: value} -> {:ok, value}
      nil -> :unknown
    end
  end

  @doc "현재 참인 모든 사실을 `%{subject => value}`로 회수한다."
  @spec recall_facts(t(), namespace()) :: %{String.t() => term()}
  def recall_facts(%__MODULE__{store: {mod, config}}, ns) do
    config
    |> mod.list(scope(ns, "semantic"))
    |> Map.new(fn {subject, %{value: value}} -> {subject, value} end)
  end

  @doc """
  subject의 대체된 과거 값들을 최신순으로 회수한다(시점 진실 + 출처 감사).

  현재 참인 값은 포함하지 않는다 — 그건 `get_fact/3`로 얻는다.
  """
  @spec fact_history(t(), namespace(), String.t()) :: [%{value: term(), at: term()}]
  def fact_history(%__MODULE__{store: {mod, config}}, ns, subject) do
    case mod.get(config, scope(ns, "semantic-history"), subject) do
      {:ok, history} when is_list(history) -> history
      :not_found -> []
    end
  end

  ## procedural — 규칙

  @doc "규칙/선호를 학습한다."
  @spec learn(t(), namespace(), String.t(), term()) :: :ok | {:error, {:not_serializable, term()}}
  def learn(%__MODULE__{} = mem, ns, name, rule),
    do: put(mem, scope(ns, "procedural"), name, %{value: rule})

  @doc "학습된 규칙을 `%{name => rule}`로 회수한다."
  @spec recall_rules(t(), namespace()) :: %{String.t() => term()}
  def recall_rules(%__MODULE__{store: {mod, config}}, ns) do
    config
    |> mod.list(scope(ns, "procedural"))
    |> Map.new(fn {name, %{value: rule}} -> {name, rule} end)
  end

  ## 시맨틱 회수 + 망각

  @doc """
  쿼리와 의미적으로 가까운 기억을 코사인 유사도로 랭킹해 회수한다.

  옵션:

    * `:embedder` (필수) — `ElGraph.Memory.Embedder`를 구현한 모듈(atom) 또는 `{module, _}`.
    * `:scope` — 검색할 스코프 (기본 `"episodic"`, `"semantic"` 등 허용).
    * `:limit` — 상위 개수 (기본 5).

  쿼리와 각 엔트리 값(binary 문자열인 것만)을 임베딩해 유사도 내림차순으로 정렬하고
  상위 `limit`개의 **값**을 돌려준다. binary가 아닌 값은 건너뛴다.
  """
  @spec recall_relevant(t(), namespace(), String.t(), keyword()) :: [term()]
  def recall_relevant(%__MODULE__{} = mem, ns, query, opts) do
    embedder = embedder_module(Keyword.fetch!(opts, :embedder))
    scope = Keyword.get(opts, :scope, "episodic")
    limit = Keyword.get(opts, :limit, 5)

    query_vec = embedder.embed(query)

    mem
    |> list(scope(ns, scope))
    |> Enum.filter(&is_binary(&1.value))
    |> Enum.map(&{cosine(query_vec, embedder.embed(&1.value)), &1.value})
    |> Enum.sort_by(fn {score, _value} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_score, value} -> value end)
  end

  @doc """
  키로 사실(`:semantic`)/규칙(`:procedural`)을 삭제한다.

  episodic은 키가 시간 정렬용 내부 키라 키 기반 삭제 대상이 아니다 — `{:error,
  :episodic_not_supported}`를 반환한다(크래시 대신 명시적 에러).
  """
  @spec forget(t(), namespace(), :semantic | :episodic | :procedural, String.t()) ::
          :ok | {:error, :episodic_not_supported}
  def forget(%__MODULE__{store: {mod, config}}, ns, :semantic, key) do
    mod.delete(config, scope(ns, "semantic-history"), key)
    mod.delete(config, scope(ns, "semantic"), key)
  end

  def forget(%__MODULE__{store: {mod, config}}, ns, :procedural, key) do
    mod.delete(config, scope(ns, "procedural"), key)
  end

  def forget(%__MODULE__{}, _ns, :episodic, _key), do: {:error, :episodic_not_supported}

  ## 내부

  defp embedder_module({mod, _}) when is_atom(mod), do: mod
  defp embedder_module(mod) when is_atom(mod), do: mod

  defp push_history(%__MODULE__{} = mem, ns, subject, prior) do
    history = fact_history(mem, ns, subject)
    put(mem, scope(ns, "semantic-history"), subject, [prior | history])
  end

  # 현재 값 + 과거 값 타임라인(최신순). fact_at의 비교 대상.
  defp timeline(%__MODULE__{store: {mod, config}} = mem, ns, subject) do
    history = fact_history(mem, ns, subject)

    case mod.get(config, scope(ns, "semantic"), subject) do
      {:ok, current} -> [current | history]
      :not_found -> history
    end
  end

  # 코사인 유사도. 0 노름이면 0.0 (divide-by-zero 가드).
  defp cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm = :math.sqrt(Enum.reduce(a, 0.0, &(&1 * &1 + &2)))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, &(&1 * &1 + &2)))

    case norm * norm_b do
      +0.0 -> 0.0
      denom -> dot / denom
    end
  end

  # 직렬화 불가능한 값(pid/ref/port/로컬 fun)은 durable Store(Postgres/Redis)에서 영속 후 재시작
  # 시 깨지므로 쓰기 전에 거부한다(체크포인트와 동일한 보장). 모든 Memory 쓰기가 이곳을 지난다.
  defp put(%__MODULE__{store: {mod, config}}, ns, key, value) do
    with :ok <- ElGraph.Checkpoint.validate_serializable(value) do
      mod.put(config, ns, key, value)
    end
  end

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
