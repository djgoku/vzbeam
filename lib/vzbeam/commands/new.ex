defmodule VzBeam.Commands.New do
  @moduledoc "new <name> <base> | new <name> --image <latest|PATH|URL|BUILD>"
  alias VzBeam.{Home, Manifest, Pidfile, Cache, Defaults}

  @reserved ~w(cache keys bin run.lock)
  @gb 1024 * 1024 * 1024

  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [image: :string, cpu: :integer, mem_gb: :integer, disk_gb: :integer])

    if invalid != [] do
      {:error, 2, "new: unknown option\n"}
    else
      case {positional, opts[:image]} do
        {[name, base], nil} -> clone(name, base, deps)
        {[name], img} when is_binary(img) -> restore(name, img, opts, deps)
        {[_, _], img} when is_binary(img) -> {:error, 2, "new: --image is mutually exclusive with a base\n"}
        _ -> {:error, 2, "usage: vzbeam new <name> <base> | new <name> --image <latest|PATH|URL|BUILD>\n"}
      end
    end
  end

  # --- clone ---------------------------------------------------------------
  defp clone(name, base, deps) do
    pending = Home.bundle_dir(name) <> ".pending"

    with :ok <- validate_name(name),
         {:ok, base_m} <- Manifest.read_or(base, :no_such_base),
         :ok <- refute_running(base),
         :ok <- refute_exists(name),
         :ok <- clear_pending(pending),
         :ok <- cp_rc(Home.bundle_dir(base), pending),
         {:ok, ids} <- deps.reid.(),
         :ok <- write_manifest(pending, clone_manifest(base_m, name, base, ids)),
         :ok <- File.rename(pending, Home.bundle_dir(name)) do
      {:ok, ["created ", name, " (clone of ", base, ")\n"]}
    else
      err -> File.rm_rf(pending); error(err)
    end
  end

  defp clone_manifest(base_m, name, base, ids) do
    Map.merge(base_m, %{
      "name" => name, "base" => base,
      "machineIdentifier" => ids.machine_identifier, "macAddress" => ids.mac_address,
      "createdAt" => now()
    })
  end

  # --- restore -------------------------------------------------------------
  defp restore(name, spec, opts, deps) do
    pending = Home.bundle_dir(name) <> ".pending"
    disk_bytes = Defaults.resolve(opts[:disk_gb], :disk_gb) * @gb
    cpu = Defaults.resolve(opts[:cpu], :cpu)
    mem_bytes = Defaults.resolve(opts[:mem_gb], :mem_gb) * @gb

    with :ok <- validate_name(name),
         :ok <- refute_exists(name),
         {:ok, status, entry} <- deps.ensure.(spec),
         :ok <- announce_image(deps, status, entry),
         :ok <- clear_pending(pending),
         :ok <- File.mkdir_p(pending),
         :ok <- create_sparse(Path.join(pending, "disk.img"), disk_bytes),
         {:ok, r} <- deps.restore.(%{ipsw: Path.join(Cache.dir(), entry["file"]),
             disk: Path.join(pending, "disk.img"), aux: Path.join(pending, "aux.img"),
             disk_size: disk_bytes, cpu: cpu, mem: mem_bytes}, restore_reporter(deps)),
         :ok <- write_manifest(pending, restore_manifest(name, entry, r, cpu, mem_bytes)),
         :ok <- File.rename(pending, Home.bundle_dir(name)) do
      {:ok, ["created ", name, " (cpu=#{cpu} mem=#{div(mem_bytes, @gb)}G disk=#{div(disk_bytes, @gb)}G)\n"]}
    else
      err -> File.rm_rf(pending); error(err)
    end
  end

  defp restore_manifest(name, entry, r, cpu, mem_bytes) do
    %{"name" => name, "base" => nil,
      "image" => %{"version" => entry["version"], "build" => entry["build"], "source" => entry["source"]},
      "machineIdentifier" => r.machine_identifier, "hardwareModel" => r.hardware_model,
      "macAddress" => r.mac_address, "cpuCount" => cpu, "memoryBytes" => mem_bytes,
      "createdAt" => now()}
  end

  # --- progress feedback ---------------------------------------------------
  # Restore is a multi-minute install; without these the terminal is silent
  # the whole time (and the cache-hit path gave no sign it skipped the download).
  defp announce_image(deps, status, e) do
    deps.progress.(image_line(status, e))
    :ok
  end

  defp image_line(:fetched, e), do: ["fetched ", e["version"], " (", e["build"], ")\n"]
  # :cached and :reconciled both mean the image was already on disk.
  defp image_line(_status, e), do: ["using cached image ", e["version"], " (", e["build"], ")\n"]

  defp restore_reporter(deps) do
    fn
      {:event, "progress", %{"fraction" => f}} when is_number(f) ->
        deps.progress.(["\rrestoring... ", Integer.to_string(round(f * 100)), "%"])

      {:event, "restored", _} ->
        deps.progress.("\rrestoring... 100%\n")

      _ ->
        :ok
    end
  end

  # ASCII only: the escript renders non-ASCII codepoints as \x{...} literals.
  defp default_progress(io), do: IO.write(:stderr, io)

  # --- helpers -------------------------------------------------------------
  defp validate_name(n) do
    cond do
      n in @reserved -> {:error, :reserved_name}
      n == "" or n in [".", ".."] or String.contains?(n, ["/", "\\"]) -> {:error, :bad_name}
      true -> :ok
    end
  end

  defp refute_running(base), do: if(Pidfile.running?(base), do: {:error, :base_running}, else: :ok)
  defp refute_exists(name), do: if(Home.exists?(name), do: {:error, :exists}, else: :ok)

  defp cp_rc(src, dst) do
    case System.cmd("cp", ["-Rc", src, dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:clone_failed, String.trim(out)}}
    end
  end

  defp write_manifest(dir, map) do
    Manifest.write_to(Path.join(dir, "config.json"), map)
  end

  defp create_sparse(path, size) do
    File.open(path, [:write, :raw], fn fd -> :file.pwrite(fd, size - 1, <<0>>) end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, err} -> err
      err -> err
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp clear_pending(pending) do
    case File.rm_rf(pending) do
      {:ok, _} -> :ok
      {:error, reason, _file} -> {:error, {:pending_cleanup, reason}}
    end
  end

  defp error({:error, :reserved_name}), do: {:error, 1, "new: name is reserved\n"}
  defp error({:error, :bad_name}), do: {:error, 1, "new: invalid name\n"}
  defp error({:error, :no_such_base}), do: {:error, 1, "new: no such base\n"}
  defp error({:error, :base_running}), do: {:error, 1, "new: base is running; stop it first\n"}
  defp error({:error, :exists}), do: {:error, 1, "new: bundle already exists\n"}
  defp error({:error, {:pending_cleanup, _}}), do: {:error, 1, "new: could not clear a stale .pending dir\n"}
  defp error({:error, reason}), do: {:error, 1, ["new failed: ", inspect(reason), "\n"]}

  defp default_deps,
    do: %{reid: &VzBeam.Sidecar.reid/0, ensure: &Cache.ensure/1,
          restore: &VzBeam.Sidecar.restore/2, progress: &default_progress/1}
end
