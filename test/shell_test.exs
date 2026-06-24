defmodule VzBeam.ShellTest do
  use ExUnit.Case, async: true

  test "single-quotes args and escapes embedded single quotes" do
    assert VzBeam.Shell.quote_arg("plain") == "'plain'"
    assert VzBeam.Shell.quote_arg("a b") == "'a b'"
    assert VzBeam.Shell.quote_arg("it's") == "'it'\\''s'"
    assert VzBeam.Shell.join(["a b", "c"]) == "'a b' 'c'"
  end
end
