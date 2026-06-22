defmodule ElGraph.AgentThreadTest do
  use ExUnit.Case, async: true

  alias ElGraph.{Agent, Reducers, Signal}
  alias ElGraph.Checkpointer.ETS

  # 매 실행마다 messages를 누적하고 현재 누적 길이를 result에 기록하는 그래프.
  defp counting_graph do
    ElGraph.new()
    |> ElGraph.state(:messages, default: [], reducer: {Reducers, :append, []})
    |> ElGraph.state(:count)
    |> ElGraph.add_node(:tick, &__MODULE__.tick/2)
    |> ElGraph.compile(entry: :tick)
  end

  def tick(%{messages: messages}, _ctx), do: %{messages: [:m], count: length(messages) + 1}

  defmodule ThreadAgent do
    use ElGraph.Agent
    @impl true
    def handle_signal(%Signal{data: data}, _ctx), do: {:run, data || %{}}
    @impl true
    def handle_result({:ok, state}, ctx),
      do: send(ctx.opts[:owner], {:done, ctx.opts[:owner] && state.count})
  end

  describe "thread policy (마찰 7)" do
    test "default :per_request — each signal starts a fresh thread (stateless)" do
      cp = start_supervised!(ETS)

      agent =
        start_supervised!(
          {ThreadAgent,
           graph: counting_graph(), id: "t1", owner: self(), checkpointer: {ETS, ETS.config(cp)}}
        )

      Agent.send_signal(agent, %Signal{type: "go", data: %{}})
      assert_receive {:done, 1}
      Agent.send_signal(agent, %Signal{type: "go", data: %{}})
      # per_request: 두 번째도 빈 상태에서 시작 → count 1
      assert_receive {:done, 1}
    end

    test "{:fixed, id} — signals accumulate in one conversation thread" do
      cp = start_supervised!(ETS)

      agent =
        start_supervised!(
          {ThreadAgent,
           graph: counting_graph(),
           id: "t2",
           owner: self(),
           checkpointer: {ETS, ETS.config(cp)},
           thread: {:fixed, "conv-1"}}
        )

      Agent.send_signal(agent, %Signal{type: "go", data: %{}})
      assert_receive {:done, 1}
      Agent.send_signal(agent, %Signal{type: "go", data: %{}})
      # fixed: 이전 messages가 이어짐 → count 2
      assert_receive {:done, 2}
    end

    test "{:fixed, id} requires a checkpointer at start" do
      assert_raise ArgumentError, ~r/checkpointer/, fn ->
        ElGraph.Agent.Server.start_link(ThreadAgent,
          graph: counting_graph(),
          id: "t3",
          thread: {:fixed, "c"}
        )
      end
    end

    test "{:fixed, id} restores completed conversation state on (re)start, without re-running" do
      cp = start_supervised!(ETS)
      cp_spec = {ETS, ETS.config(cp)}

      # 이전 생애: 한 번 실행해 완료 체크포인트(next: [])를 남긴다.
      {:ok, %{count: 1}} =
        ElGraph.invoke(counting_graph(), %{}, checkpointer: cp_spec, thread_id: "conv-restore")

      agent =
        start_supervised!(
          {ThreadAgent,
           graph: counting_graph(),
           id: "tr",
           owner: self(),
           checkpointer: cp_spec,
           thread: {:fixed, "conv-restore"}}
        )

      # 완료된 thread는 복원만 하고 재실행하지 않는다.
      refute_receive {:done, _}, 100

      # 다음 시그널은 복원된 상태에서 누적된다 → count 2.
      Agent.send_signal(agent, %Signal{type: "go", data: %{}})
      assert_receive {:done, 2}
    end
  end
end
