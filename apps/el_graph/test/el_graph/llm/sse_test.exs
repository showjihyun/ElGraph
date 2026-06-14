defmodule ElGraph.LLM.SSETest do
  use ExUnit.Case, async: true

  alias ElGraph.LLM.SSE

  describe "parse/2 — incremental SSE framing" do
    test "extracts a single complete data event" do
      assert {["{\"a\":1}"], ""} = SSE.parse("", "data: {\"a\":1}\n\n")
    end

    test "buffers a partial event across chunks" do
      assert {[], "data: {\"a\":" = buf} = SSE.parse("", "data: {\"a\":")
      assert {["{\"a\":1}"], ""} = SSE.parse(buf, "1}\n\n")
    end

    test "filters [DONE] sentinel" do
      assert {[], ""} = SSE.parse("", "data: [DONE]\n\n")
    end

    test "extracts multiple events in one chunk" do
      assert {["1", "2"], ""} = SSE.parse("", "data: 1\n\ndata: 2\n\n")
    end

    test "ignores comment and non-data lines" do
      assert {["1"], ""} = SSE.parse("", ": ping\n\nevent: foo\ndata: 1\n\n")
    end

    test "tolerates data with no leading space" do
      assert {["x"], ""} = SSE.parse("", "data:x\n\n")
    end

    test "keeps an incomplete trailing event in the buffer" do
      assert {["1"], "data: 2"} = SSE.parse("", "data: 1\n\ndata: 2")
    end
  end
end
