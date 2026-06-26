defmodule VzBeam.DisplaysTest do
  use ExUnit.Case, async: true
  alias VzBeam.Displays

  @fixture File.read!(Path.expand("support/displays_fixture.json", __DIR__))

  test "parses the captured fixture into at least one display with native pixels" do
    [d | _] = Displays.parse(@fixture)
    assert is_binary(d.name) and d.width > 0 and d.height > 0
  end

  test "suggestions: native, half, and the vzbeam default, deduped" do
    displays = [%{name: "X", width: 3024, height: 1964, main: true, looks_like: nil}]
    assert Displays.suggestions(displays) == ["3024x1964", "1512x982", "1920x1200"]
  end

  test "no displays -> just the default suggestion" do
    assert Displays.suggestions([]) == ["1920x1200"]
  end

  test "parse tolerates garbage, no SPDisplaysDataType, and pixel-less entries" do
    assert Displays.parse("not json") == []
    assert Displays.parse(~s({"other":1})) == []
    assert Displays.parse(~s({"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"No Pixels"}]}]})) == []
  end

  test "non-binary _spdisplays_resolution is coerced to nil so looks_like stays String.t()|nil" do
    json = ~s({"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"Test","_spdisplays_pixels":"100 x 200","_spdisplays_resolution":123}]}]})
    [d] = Displays.parse(json)
    assert d.looks_like == nil
    assert d.width == 100
    assert d.height == 200
  end
end
