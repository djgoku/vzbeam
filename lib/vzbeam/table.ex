defmodule VzBeam.Table do
  @moduledoc "Render equal-length string rows as a padded text table (iodata)."

  @spec render([[String.t()]]) :: iodata
  def render(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn col -> col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map(rows, fn cols ->
      cols
      |> Enum.zip(widths)
      |> Enum.map(fn {c, w} -> String.pad_trailing(c, w + 2) end)
      |> then(&[&1, "\n"])
    end)
  end
end
