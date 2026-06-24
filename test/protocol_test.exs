defmodule VzBeam.ProtocolTest do
  use ExUnit.Case, async: true
  alias VzBeam.Protocol

  test "decode_line tags by type / flags bad json / missing type / oversize" do
    assert {:event, "image", %{"build" => "25F80"}} =
             Protocol.decode_line(~s({"type":"image","build":"25F80"}))
    assert {:error, :bad_json} = Protocol.decode_line("not json")
    assert {:error, :missing_type} = Protocol.decode_line(~s({"x":1}))
    assert {:error, :oversize} = Protocol.decode_line(String.duplicate("x", 1_048_577))
  end

  test "collect finds the terminal event" do
    lines = [~s({"type":"progress","fraction":0.5}), ~s({"type":"restored","build":"25F80"})]
    assert {:ok, _events, {:event, "restored", %{"build" => "25F80"}}} =
             Protocol.collect(lines, ["restored"], true)
  end

  test "collect: error event dominates even with a terminal present" do
    lines = [~s({"type":"restored","build":"X"}), ~s({"type":"error","domain":"VZ","code":6,"message":"boom"})]
    assert {:error, {:vz, "VZ", 6, "boom"}} = Protocol.collect(lines, ["restored"], true)
  end

  test "collect: no terminal -> :no_terminal; unterminated final line -> :unterminated" do
    assert {:error, :no_terminal} = Protocol.collect([~s({"type":"progress"})], ["restored"], true)
    assert {:error, :unterminated} = Protocol.collect([~s({"type":"restored"})], ["restored"], false)
  end

  test "collect: unknown types are ignored, never terminal" do
    assert {:error, :no_terminal} = Protocol.collect([~s({"type":"weird"})], ["restored"], true)
  end
end
