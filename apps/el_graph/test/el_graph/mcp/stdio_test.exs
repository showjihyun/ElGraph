defmodule ElGraph.MCP.StdioTest do
  use ExUnit.Case, async: true

  alias ElGraph.MCP.Stdio
  alias ElGraph.TestActions.Search

  defp deps, do: %{tools: [Search], server_info: %{"name" => "elgraph", "version" => "0.2.0"}}

  describe "process_line/2" do
    test "replies to a request with a JSON-RPC envelope" do
      line = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
      assert {:reply, json} = Stdio.process_line(line, deps())

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"protocolVersion" => _}} =
               Jason.decode!(json)
    end

    test "does not reply to a notification" do
      line = ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
      assert :notification = Stdio.process_line(line, deps())
    end

    test "replies with a parse error on invalid JSON" do
      assert {:reply, json} = Stdio.process_line("not json", deps())
      assert %{"error" => %{"code" => -32700}} = Jason.decode!(json)
    end

    test "ignores a blank line" do
      assert :notification = Stdio.process_line("  \n", deps())
    end
  end

  describe "serve/2 over IO devices" do
    test "reads newline-delimited requests and writes one response per request" do
      requests =
        [
          ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}),
          ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"x"}}})
        ]
        |> Enum.join("\n")

      {:ok, input} = StringIO.open(requests)
      {:ok, output} = StringIO.open("")

      assert :ok = Stdio.serve(deps(), input: input, output: output)

      {_, written} = StringIO.contents(output)
      lines = written |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert [
               %{"id" => 1, "result" => %{"tools" => _}},
               %{"id" => 2, "result" => %{"isError" => false}}
             ] =
               lines
    end
  end
end
