defmodule VzBeam.Commands.DisplaysTest do
  use ExUnit.Case, async: true
  alias VzBeam.Commands.Displays

  @json ~s({"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"Color LCD","_spdisplays_pixels":"3024 x 1964","_spdisplays_resolution":"1512 x 982 @ 120.00Hz","spdisplays_main":"spdisplays_yes"}]}]})

  test "prints the display and suggested resolutions" do
    assert {:ok, out} = Displays.run([], fn -> @json end)
    s = IO.iodata_to_binary(out)
    assert s =~ "Color LCD" and s =~ "3024 x 1964" and s =~ "suggested --resolution"
    assert s =~ "3024x1964" and s =~ "1920x1200"
    assert s =~ "looks like"
  end

  test "no display -> friendly fallback, exit 0" do
    assert {:ok, out} = Displays.run([], fn -> "" end)
    assert IO.iodata_to_binary(out) =~ "no display detected"
  end

  test "rejects extra args (exit 2), consistent with other verbs" do
    assert {:error, 2, _} = Displays.run(["extra"], fn -> @json end)
  end
end
