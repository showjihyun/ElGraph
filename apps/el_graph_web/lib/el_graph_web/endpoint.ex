defmodule ElGraphWeb.Endpoint do
  @moduledoc """
  최상위 Plug — 에이전트 레지스트리를 `conn.assigns`에 주입하고 `ElGraphWeb.Router`로 넘긴다.
  Bandit `plug:` 옵션으로 마운트된다 (`ElGraphWeb.server_spec/1`).
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      agents: Map.new(Keyword.get(opts, :agents, %{})),
      task_store: Keyword.get(opts, :task_store),
      api_keys: Keyword.get(opts, :api_keys, []),
      guardrails: Keyword.get(opts, :guardrails, [])
    }
  end

  @impl true
  def call(conn, %{agents: agents, task_store: task_store} = opts) do
    conn
    |> Plug.Conn.assign(:agents, agents)
    |> Plug.Conn.assign(:task_store, task_store)
    |> Plug.Conn.assign(:api_keys, opts.api_keys)
    |> Plug.Conn.assign(:guardrails, opts.guardrails)
    |> ElGraphWeb.Router.call(ElGraphWeb.Router.init([]))
  end
end
