defmodule VzBeam.Commands.Images do
  @moduledoc "images — one table of restore images: cached (local) and what Apple currently offers (remote)."

  @header ["VERSION", "BUILD", "SIZE", "STATUS"]

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([], deps) do
    local = deps.list.()
    cached = MapSet.new(local, & &1["build"])

    rows =
      (Enum.map(local, &local_row/1) ++ Enum.map(remote(deps, cached), &remote_row/1))
      |> Enum.sort_by(fn [_v, build | _] -> build end, :desc)

    {:ok, VzBeam.Table.render([@header | rows])}
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam images\n"}

  # Offline (or a catalog hiccup) must not break the listing: fall back to
  # cached-only with a note on stderr, exit 0.
  defp remote(deps, cached) do
    case deps.remote.() do
      {:ok, entries} ->
        Enum.reject(entries, &MapSet.member?(cached, &1["build"]))

      {:error, reason} ->
        deps.warn.(["note: could not reach Apple's catalog (", inspect(reason),
                    "); showing cached images only\n"])
        []
    end
  end

  defp local_row(e), do: [e["version"] || "-", e["build"] || "-", size(e["bytes"]), "local"]
  defp remote_row(e), do: [e["version"], e["build"], "-", "remote"]

  defp size(b) when is_number(b), do: "#{trunc(b / (1024 * 1024 * 1024))}G"
  defp size(_), do: "-"

  defp default_deps do
    %{list: &VzBeam.Cache.list/0, remote: &VzBeam.Catalog.list/0,
      warn: fn io -> IO.write(:stderr, io) end}
  end
end
