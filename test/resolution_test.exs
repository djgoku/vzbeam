defmodule VzBeam.ResolutionTest do
  use ExUnit.Case, async: true
  alias VzBeam.Resolution

  test "parses the anchored lowercase positive resolution grammar" do
    assert {:ok, {1280, 800}} = Resolution.parse("1280x800")

    for value <- [nil, "", "0x800", "1280x0", "1280X800", "1280x800junk"] do
      assert {:error, :bad_resolution} = Resolution.parse(value)
    end
  end
end
