defmodule VzBeam.Commands.Displays do
  @moduledoc "displays — show host display(s) and suggested --resolution values."
  alias VzBeam.Displays

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, &profiler/0)

  def run([], profiler) do
    case Displays.parse(profiler.()) do
      [] -> {:ok, "no display detected; vzbeam default is 1920x1200\n"}
      displays -> {:ok, [Enum.map(displays, &line/1), suggest(displays)]}
    end
  end

  def run(_args, _profiler), do: {:error, 2, "usage: vzbeam displays\n"}

  defp line(%{name: n, width: w, height: h} = d) do
    looks = if d.looks_like, do: ["   (looks like ", d.looks_like, ")"], else: []
    [n, "   ", to_string(w), " x ", to_string(h), " native", looks, "\n"]
  end

  defp suggest(displays) do
    ["suggested --resolution:\n" | Enum.map(Displays.suggestions(displays), &["  ", &1, "\n"])]
  end

  defp profiler do
    case System.cmd("system_profiler", ["SPDisplaysDataType", "-json"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  end
end
