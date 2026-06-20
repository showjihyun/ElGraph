defmodule ElGraph.LLM.DriverFakeProvider do
  @moduledoc false
  # 최소 Provider — Driver 머신(전송·SSE·fold·usage 병합·status·instrument)을 어떤 실제
  # 벤더와도 무관하게 격리 검증하기 위한 가짜 매핑.
  @behaviour ElGraph.LLM.Provider

  alias ElGraph.LLM

  @impl true
  def request_spec(_config, _messages, _opts, _mode),
    do: %{url: "http://fake.test/v1", headers: [{"x-test", "1"}], body: %{}, model: "fake-model"}

  @impl true
  def parse_response(%{"text" => text} = body) do
    usage =
      case body["usage"] do
        %{"in" => i, "out" => o} -> %{input_tokens: i, output_tokens: o}
        _ -> nil
      end

    {:ok, %{message: LLM.assistant(text, []), usage: usage}}
  end

  def parse_response(other), do: {:error, {:unexpected_response, other}}

  @impl true
  def init_stream_state, do: %{}

  @impl true
  def decode_deltas(%{"t" => "tok", "v" => v}, s), do: {[{:token, v}], s}

  def decode_deltas(%{"t" => "tool_start", "id" => id, "name" => n}, s),
    do: {[{:tool_call_start, id, n}], s}

  def decode_deltas(%{"t" => "tool_arg", "id" => id, "frag" => f}, s),
    do: {[{:tool_call_delta, id, f}], s}

  def decode_deltas(%{"t" => "tool_end", "id" => id}, s), do: {[{:tool_call_end, id}], s}
  def decode_deltas(_chunk, s), do: {[], s}

  @impl true
  def decode_usage(%{"t" => "usage_in", "v" => v}), do: %{input_tokens: v}
  def decode_usage(%{"t" => "usage_out", "v" => v}), do: %{output_tokens: v}
  def decode_usage(_chunk), do: nil
end

defmodule ElGraph.LLM.DriverTest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM
  alias ElGraph.LLM.Driver
  alias ElGraph.LLM.DriverFakeProvider, as: Fake

  defp config(stub), do: [req_options: [plug: {Req.Test, stub}]]

  defp sse(chunks),
    do: Enum.map_join(chunks, "", &"data: #{JSON.encode!(&1)}\n\n") <> "data: [DONE]\n\n"

  describe "chat/5" do
    test "parses a 200 response via the provider and instruments the span" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:el_graph, :llm, :chat, :stop]])

      Req.Test.stub(DriverChatOK, fn conn ->
        Req.Test.json(conn, %{"text" => "hi", "usage" => %{"in" => 4, "out" => 2}})
      end)

      assert {:ok,
              %{
                message: %{role: :assistant, content: "hi", tool_calls: []},
                usage: %{input_tokens: 4, output_tokens: 2}
              }} = Driver.chat(Fake, :fake, config(DriverChatOK), [LLM.user("x")], [])

      assert_receive {[:el_graph, :llm, :chat, :stop], ^ref, %{duration: _},
                      %{provider: :fake, model: "fake-model", input_tokens: 4, output_tokens: 2}}
    end

    test "maps a non-200 response to {:api_error, status, body}" do
      Req.Test.stub(DriverChatErr, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:error, {:api_error, 503, _}} =
               Driver.chat(Fake, :fake, config(DriverChatErr), [LLM.user("x")], [])
    end

    test "maps a transport failure to {:transport_error, exception}" do
      Req.Test.stub(DriverChatT, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               Driver.chat(Fake, :fake, config(DriverChatT), [LLM.user("x")], [])
    end
  end

  describe "stream_chat/5 — emit live + fold from the delta grammar" do
    test "folds tokens, emits deltas live, merges usage across chunks" do
      chunks = [
        %{"t" => "usage_in", "v" => 7},
        %{"t" => "tok", "v" => "Hel"},
        %{"t" => "tok", "v" => "lo"},
        %{"t" => "usage_out", "v" => 2}
      ]

      Req.Test.stub(DriverStreamText, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse(chunks))
      end)

      parent = self()

      assert {:ok,
              %{
                message: %{role: :assistant, content: "Hello", tool_calls: []},
                usage: %{input_tokens: 7, output_tokens: 2}
              }} =
               Driver.stream_chat(Fake, :fake, config(DriverStreamText), [LLM.user("x")],
                 on_delta: fn d -> send(parent, {:d, d}) end
               )

      assert_received {:d, {:token, "Hel"}}
      assert_received {:d, {:token, "lo"}}
    end

    test "assembles a tool call from start/delta/end deltas" do
      chunks = [
        %{"t" => "tool_start", "id" => "c1", "name" => "f"},
        %{"t" => "tool_arg", "id" => "c1", "frag" => "{\"q\":"},
        %{"t" => "tool_arg", "id" => "c1", "frag" => "\"x\"}"},
        %{"t" => "tool_end", "id" => "c1"}
      ]

      Req.Test.stub(DriverStreamTool, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse(chunks))
      end)

      assert {:ok,
              %{
                message: %{
                  content: nil,
                  tool_calls: [%{id: "c1", name: "f", args: %{"q" => "x"}}]
                }
              }} = Driver.stream_chat(Fake, :fake, config(DriverStreamTool), [LLM.user("x")], [])
    end

    test "maps a non-200 streaming response to {:api_error, status, body}" do
      Req.Test.stub(DriverStream500, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(500, "boom")
      end)

      assert {:error, {:api_error, 500, _}} =
               Driver.stream_chat(Fake, :fake, config(DriverStream500), [LLM.user("x")], [])
    end

    test "maps a transport failure to {:transport_error, exception}" do
      Req.Test.stub(DriverStreamT, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
               Driver.stream_chat(Fake, :fake, config(DriverStreamT), [LLM.user("x")], [])
    end
  end
end
