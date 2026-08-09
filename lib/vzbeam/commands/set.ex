defmodule VzBeam.Commands.Set do
  @moduledoc "set <name> [--cpu N] [--mem-gb M] [--disk-gb G] — change a stopped VM's CPU/RAM/disk (disk grows only)."
  alias VzBeam.{Manifest, Pidfile, Home, Disk}

  @gb 1024 * 1024 * 1024

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [cpu: :integer, mem_gb: :integer, disk_gb: :integer])

    cond do
      invalid != [] -> {:error, 2, "set: invalid option\n"}
      not match?([_], positional) or opts == [] -> usage()
      true -> apply_set(hd(positional), opts)
    end
  end

  defp apply_set(name, opts) do
    with :ok <- validate(opts),
         {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- refute_running(name),
         :ok <- maybe_grow_disk(name, opts[:disk_gb]),
         updated = update(m, opts),
         :ok <- Manifest.write_to(Manifest.path(name), updated) do
      {:ok, [summary(name, updated) | disk_hint(name, opts[:disk_gb])]}
    else
      err -> error(name, err)
    end
  end

  defp summary(name, m) do
    ["set ", name, ": cpu=", to_string(m["cpuCount"]),
     " mem=", to_string(div(m["memoryBytes"], @gb)), "G",
     " disk=", Disk.gb(Disk.size(disk_path(name))), "\n"]
  end

  # The guest's APFS container doesn't grow with the image; remind how.
  defp disk_hint(_name, nil), do: []
  defp disk_hint(name, _gb) do
    ["note: the guest sees the new size, but its APFS container must be grown inside the VM:\n",
     "  vzbeam ssh ", name, " -- sudo diskutil apfs resizeContainer disk0s2 0\n"]
  end

  defp maybe_grow_disk(_name, nil), do: :ok

  defp maybe_grow_disk(name, gb) do
    case Disk.grow(disk_path(name), gb * @gb) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :no_disk}
      err -> err
    end
  end

  defp disk_path(name), do: Path.join(Home.bundle_dir(name), "disk.img")

  defp validate(opts) do
    cond do
      is_integer(opts[:cpu]) and opts[:cpu] < 1 -> {:error, :bad_cpu}
      is_integer(opts[:mem_gb]) and opts[:mem_gb] < 1 -> {:error, :bad_mem}
      is_integer(opts[:disk_gb]) and opts[:disk_gb] < 1 -> {:error, :bad_disk}
      true -> :ok
    end
  end

  defp update(m, opts) do
    m
    |> maybe_put("cpuCount", opts[:cpu])
    |> maybe_put("memoryBytes", opts[:mem_gb] && opts[:mem_gb] * @gb)
  end

  defp maybe_put(m, _key, nil), do: m
  defp maybe_put(m, key, val), do: Map.put(m, key, val)

  defp refute_running(name), do: if(Pidfile.running?(name), do: {:error, :running}, else: :ok)
  defp usage, do: {:error, 2, "usage: vzbeam set <name> [--cpu N] [--mem-gb M] [--disk-gb G]\n"}

  defp error(_n, {:error, :no_such_bundle}), do: {:error, 1, "set: no such bundle\n"}
  defp error(name, {:error, :running}), do: {:error, 1, ["set: ", name, " is running; stop it first\n"]}
  defp error(_n, {:error, :bad_cpu}), do: {:error, 2, "set: --cpu must be >= 1\n"}
  defp error(_n, {:error, :bad_mem}), do: {:error, 2, "set: --mem-gb must be >= 1\n"}
  defp error(_n, {:error, :bad_disk}), do: {:error, 2, "set: --disk-gb must be >= 1\n"}
  defp error(_n, {:error, :no_disk}), do: {:error, 1, "set: bundle has no disk.img\n"}

  defp error(_n, {:error, {:shrink, have}}),
    do: {:error, 1, ["set: disk can only grow (current ", Disk.gb(have), ")\n"]}

  defp error(_n, {:error, reason}), do: {:error, 1, ["set failed: ", inspect(reason), "\n"]}
end
