defmodule VzBeam.Commands.Images do
  @moduledoc "images — list cached restore images."

  @header ["VERSION", "BUILD", "SIZE", "SOURCE"]

  @spec run([String.t()]) :: {:ok, iodata}
  def run(args), do: run(args, &VzBeam.Cache.list/0)

  def run(_args, list_fn) do
    rows =
      Enum.map(list_fn.(), fn e ->
        [e["version"] || "-", e["build"] || "-", size(e["bytes"]), e["source"] || "-"]
      end)

    {:ok, VzBeam.Table.render([@header | rows])}
  end

  defp size(b) when is_number(b), do: "#{trunc(b / (1024 * 1024 * 1024))}G"
  defp size(_), do: "-"
end
