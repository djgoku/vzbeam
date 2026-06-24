defmodule VzBeam.TableTest do
  use ExUnit.Case, async: true

  test "pads each column to its widest cell + 2 and newline-terminates rows" do
    out = VzBeam.Table.render([["NAME", "OS"], ["base", "26.5.1"]]) |> IO.iodata_to_binary()
    assert out == "NAME  OS      \nbase  26.5.1  \n"
  end
end
