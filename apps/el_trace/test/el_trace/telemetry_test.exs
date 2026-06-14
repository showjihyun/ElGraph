defmodule ElTrace.TelemetryTest do
  # 텔레메트리 핸들러는 전역 상태라 attach/detach를 직렬화한다.
  use ExUnit.Case, async: false

  alias ElTrace.Telemetry

  setup do
    :ok = Telemetry.attach()
    on_exit(&Telemetry.detach/0)
    :ok
  end

  test "노드 stop을 thread 토픽으로 브로드캐스트한다" do
    Phoenix.PubSub.subscribe(ElTrace.PubSub, Telemetry.thread_topic("t-node"))

    :telemetry.execute([:el_graph, :node, :stop], %{duration: 1}, %{
      thread_id: "t-node",
      node: :foo,
      step: 2
    })

    assert_receive {:thread_event, %{thread_id: "t-node", kind: :node_stop, node: :foo, step: 2}}
  end

  test "인터럽트를 thread 토픽으로 브로드캐스트한다" do
    Phoenix.PubSub.subscribe(ElTrace.PubSub, Telemetry.thread_topic("t-int"))

    :telemetry.execute([:el_graph, :node, :interrupt], %{}, %{
      thread_id: "t-int",
      node: :approve,
      step: 1,
      payload: %{amount: 100}
    })

    assert_receive {:thread_event,
                    %{thread_id: "t-int", kind: :interrupt, node: :approve, step: 1}}
  end

  test "invoke stop(실행 완료)을 thread 토픽으로 브로드캐스트한다" do
    Phoenix.PubSub.subscribe(ElTrace.PubSub, Telemetry.thread_topic("t-done"))

    :telemetry.execute([:el_graph, :invoke, :stop], %{duration: 5}, %{thread_id: "t-done"})

    assert_receive {:thread_event, %{thread_id: "t-done", kind: :invoke_stop}}
  end

  test "다른 thread 구독자에게는 가지 않는다" do
    Phoenix.PubSub.subscribe(ElTrace.PubSub, Telemetry.thread_topic("listening"))

    :telemetry.execute([:el_graph, :node, :stop], %{duration: 1}, %{
      thread_id: "other",
      node: :foo,
      step: 1
    })

    refute_receive {:thread_event, _}, 50
  end
end
