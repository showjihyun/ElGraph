defmodule ElGraph.Test.ScriptedLLM do
  @moduledoc """
  테스트용 스크립트 LLM (테스트 키트, SPEC §7).

  응답 목록을 순서대로 반환하고 받은 호출(messages/opts)을 기록한다.

      {:ok, pid} = ScriptedLLM.start_link([LLM.assistant("hi")])
      graph = ElGraph.Presets.react({ScriptedLLM, pid}, tools)
      # ... 이후 ScriptedLLM.calls(pid)로 LLM이 받은 입력을 검증

  스크립트 원소: assistant 메시지 맵(자동으로 `{:ok, response}` 포장) 또는
  `{:ok, response}` / `{:error, reason}` 원형. 소진되면 `{:error, :script_exhausted}`.
  """

  @behaviour ElGraph.LLM

  @spec start_link([term()]) :: Agent.on_start()
  def start_link(script) when is_list(script) do
    Agent.start_link(fn -> %{script: script, calls: []} end)
  end

  @doc "지금까지 받은 호출 목록(`%{messages:, opts:}`)을 순서대로 반환한다."
  @spec calls(pid()) :: [%{messages: [map()], opts: keyword()}]
  def calls(pid), do: Agent.get(pid, &Enum.reverse(&1.calls))

  @impl ElGraph.LLM
  def chat(pid, messages, opts) do
    Agent.get_and_update(pid, fn state ->
      state = %{state | calls: [%{messages: messages, opts: opts} | state.calls]}

      case state.script do
        [] -> {{:error, :script_exhausted}, state}
        [next | rest] -> {wrap(next), %{state | script: rest}}
      end
    end)
  end

  @doc """
  `chat/3`의 스트리밍 변형. 스크립트 원소가 `{:deltas, parts, message}`면 각 part를
  `on_delta`로 차례로 방출하고, 일반 assistant 메시지면 content 전체를 토큰 1개로 방출한다.
  """
  @impl ElGraph.LLM
  def stream_chat(pid, messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

    next =
      Agent.get_and_update(pid, fn state ->
        state = %{state | calls: [%{messages: messages, opts: opts} | state.calls]}

        case state.script do
          [] -> {{:error, :script_exhausted}, state}
          [next | rest] -> {next, %{state | script: rest}}
        end
      end)

    stream_result(next, on_delta)
  end

  defp stream_result({:error, _reason} = error, _on_delta), do: error

  defp stream_result({:deltas, parts, message}, on_delta) do
    Enum.each(parts, fn part -> on_delta.({:token, part}) end)
    wrap(message)
  end

  defp stream_result(other, on_delta) do
    {:ok, response} = result = wrap(other)
    emit_content(response.message, on_delta)
    result
  end

  defp emit_content(%{content: content}, on_delta) when is_binary(content),
    do: on_delta.({:token, content})

  defp emit_content(_message, _on_delta), do: :ok

  defp wrap({:error, _reason} = error), do: error
  defp wrap({:ok, _response} = ok), do: ok

  defp wrap(%{role: :assistant} = message),
    do: {:ok, %{message: message, usage: %{input_tokens: 0, output_tokens: 0}}}
end
