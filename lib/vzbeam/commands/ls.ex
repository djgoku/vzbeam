defmodule VzBeam.Commands.Ls do
  @moduledoc "ls — table of bundles."
  alias VzBeam.{Home, Manifest, Pidfile, Leases}

  @header ["NAME", "STATUS", "BASE", "OS", "IP", "CPU", "MEM", "DISK"]

  @spec run([String.t()]) :: {:ok, iodata}
  def run(args), do: run(args, &VzBeam.Leases.read/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata}
  def run(_args, read_leases) do
    leases = read_leases.()
    rows = Enum.map(Home.bundles(), &row(&1, leases))
    {:ok, render([@header | rows])}
  end

  defp row(name, leases) do
    m = case Manifest.read(name), do: ({:ok, map} -> map; _ -> %{})
    img = Map.get(m, "image") || %{}
    [
      name,
      if(Pidfile.running?(name), do: "running", else: "stopped"),
      m["base"] || "-",
      os(img),
      ip(m, leases),
      to_string(m["cpuCount"] || "-"),
      mem(m["memoryBytes"]),
      "-"
    ]
  end

  defp os(%{"version" => v, "build" => b}), do: "#{v} (#{b})"
  defp os(_), do: "-"

  defp ip(%{"macAddress" => mac}, leases) when is_binary(mac),
    do: Leases.lookup_ip(leases, mac) || "-"

  defp ip(_, _), do: "-"

  defp mem(bytes) when is_number(bytes), do: "#{trunc(bytes / (1024 * 1024 * 1024))}G"
  defp mem(_), do: "-"

  defp render(rows) do
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
