defmodule VzBeam.Commands.Ls do
  @moduledoc "ls — table of bundles."
  alias VzBeam.{Home, Manifest, Pidfile, Leases, Disk, GuestPolicy}

  @header ["NAME", "STATUS", "BASE", "OS", "IP", "CPU", "MEM", "DISK"]

  @spec run([String.t()]) :: {:ok, iodata}
  def run(args), do: run(args, &VzBeam.Leases.read/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata}
  def run(_args, read_leases) do
    leases = read_leases.()
    rows = Enum.map(Home.bundles(), &row(&1, leases))
    {:ok, VzBeam.Table.render([@header | rows])}
  end

  defp row(name, leases) do
    case Manifest.read(name) do
      {:ok, manifest} -> valid_row(name, manifest, leases)
      {:error, reason} -> invalid_row(name, reason)
    end
  end

  defp valid_row(name, manifest, leases) do
    [
      name,
      if(Pidfile.running?(name), do: "running", else: "stopped"),
      manifest["base"] || "-",
      GuestPolicy.os_label(manifest, manifest["image"] || %{}),
      ip(manifest, leases),
      to_string(manifest["cpuCount"] || "-"),
      mem(manifest["memoryBytes"]),
      Disk.gb(Disk.size(Path.join(Home.bundle_dir(name), "disk.img")))
    ]
  end

  defp invalid_row(name, reason) do
    [
      name,
      if(Pidfile.running?(name), do: "running", else: "stopped"),
      "-",
      describe_manifest_error(reason),
      "-",
      "-",
      "-",
      Disk.gb(Disk.size(Path.join(Home.bundle_dir(name), "disk.img")))
    ]
  end

  defp describe_manifest_error(:invalid_manifest), do: Manifest.describe_error(:invalid_manifest)

  defp describe_manifest_error({:unsupported_schema, _} = reason),
    do: Manifest.describe_error(reason)

  defp describe_manifest_error({:unsupported_guest, _} = reason),
    do: Manifest.describe_error(reason)

  defp describe_manifest_error(reason), do: inspect(reason)

  defp ip(%{"macAddress" => mac}, leases) when is_binary(mac),
    do: Leases.lookup_ip(leases, mac) || "-"

  defp ip(_, _), do: "-"

  defp mem(bytes) when is_number(bytes), do: "#{trunc(bytes / (1024 * 1024 * 1024))}G"
  defp mem(_), do: "-"
end
