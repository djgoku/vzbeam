defmodule VzBeam.Commands.ImagesTest do
  use ExUnit.Case, async: true

  test "renders a table with header and rows" do
    list = fn -> [%{"version" => "26.5.1", "build" => "25F80", "bytes" => 16_000_000_000, "source" => "latest"}] end
    assert {:ok, out} = VzBeam.Commands.Images.run([], list)
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/VERSION\s+BUILD\s+SIZE\s+SOURCE/
    assert text =~ "25F80"
  end

  test "empty cache prints just the header" do
    assert {:ok, out} = VzBeam.Commands.Images.run([], fn -> [] end)
    assert IO.iodata_to_binary(out) =~ "VERSION"
  end
end
