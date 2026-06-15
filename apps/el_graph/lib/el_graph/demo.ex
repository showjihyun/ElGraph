defmodule ElGraph.Demo do
  @moduledoc """
  도그푸딩 데모: ElGraph 문서 Q&A 에이전트의 supervision 트리 (SPEC §8 M3 완료 기준).

      {:ok, _pid} = ElGraph.Demo.start_link([])     # 실 OpenAI 키 (config/secrets.exs)
      ElGraph.Demo.ask("체크포인트 보존 정책이 뭐야?")
      # reply_to 프로세스가 {:demo_answer, answer}를 받는다

  상시 구동: `mix run --no-halt scripts/demo.exs`
  실행 관측: `ElGraph.Demo.runs()` (Runner introspection)

  트리 구성(rest_for_one): 에이전트 Registry → introspection Registry →
  ETS 체크포인터(keep: {:last, 50}) → RateLimiter(limit 3) → DocsAgent.
  """

  use Supervisor

  alias ElGraph.Checkpointer.ETS

  @agent_registry __MODULE__.AgentRegistry
  @run_registry __MODULE__.RunRegistry
  @checkpointer __MODULE__.Checkpointer
  @agent_id "docs"

  # 도그푸딩 데모(DocsSearch/DocsWatch)가 검색하는 저장소 루트의 docs/.
  # 우산 전환 후 테스트 CWD가 앱 디렉터리라 CWD 상대 경로가 깨졌다 — 컴파일 타임에 루트를 고정한다.
  @docs_dir Path.expand("../../../../docs", __DIR__)

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: @agent_registry},
      {Registry, keys: :unique, name: @run_registry},
      {ETS, name: @checkpointer, keep: {:last, 50}},
      {ElGraph.RateLimiter, limit: 3, name: __MODULE__.Limiter},
      %{
        id: :docs_agent,
        start: {__MODULE__, :start_agent, [opts]},
        restart: :permanent
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def start_agent(opts) do
    ElGraph.Demo.DocsAgent.start_link(
      Keyword.merge(opts,
        id: @agent_id,
        registry: @agent_registry,
        run_registry: @run_registry,
        checkpointer: {ETS, ETS.config(@checkpointer)},
        rate_limiter: __MODULE__.Limiter,
        # 대화형 Q&A — 연속 질문이 한 대화 thread에 누적된다 (마찰 7).
        thread: {:fixed, "demo-conversation"}
      )
    )
  end

  @doc "에이전트에 질문을 보낸다 (비동기 — 답은 reply_to로 온다)."
  @spec ask(String.t()) :: :ok
  def ask(question) when is_binary(question) do
    ElGraph.Agent.send_signal(
      ElGraph.Agent.via(@agent_registry, @agent_id),
      %ElGraph.Signal{
        type: "question.asked",
        source: "el_graph_demo",
        data: %{question: question}
      }
    )
  end

  @doc "실행 중인 그래프 run 목록 (introspection)."
  def runs, do: ElGraph.Runner.list(@run_registry)

  @doc "도그푸딩 데모가 검색하는 저장소 루트 docs/ 디렉터리의 `*.md` glob (CWD 비의존)."
  def docs_glob, do: Path.join(@docs_dir, "*.md")

  @doc false
  def fetch_api_key! do
    System.get_env("OPENAI_API_KEY") || secrets_key() ||
      raise "OPENAI_API_KEY 환경변수 또는 config/secrets.exs의 :openai_api_key가 필요합니다"
  end

  # 저장소 루트 config/secrets.exs (gitignore됨) — CWD 비의존(@docs_dir와 동일 방식).
  @secrets_path Path.expand("../../../../config/secrets.exs", __DIR__)

  defp secrets_key do
    if File.exists?(@secrets_path) do
      {secrets, _bindings} = Code.eval_file(@secrets_path)
      secrets[:openai_api_key]
    end
  end
end
