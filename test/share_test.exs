defmodule VzBeam.ShareTest do
  use ExUnit.Case, async: true

  test "parses a valid tag=/path (first = splits; host dir must exist)" do
    dir = System.tmp_dir!()
    assert {:ok, %{tag: "shared", path: ^dir}} = VzBeam.Share.parse("shared=#{dir}")
  end

  test "rejects bad specs" do
    assert {:error, :no_equals}   = VzBeam.Share.parse("noequals")
    assert {:error, :empty_tag}   = VzBeam.Share.parse("=#{System.tmp_dir!()}")
    assert {:error, :tag_too_long} = VzBeam.Share.parse(String.duplicate("x", 37) <> "=#{System.tmp_dir!()}")
    assert {:error, :no_such_dir} = VzBeam.Share.parse("t=/no/such/dir/xyz")
  end
end
