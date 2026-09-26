defmodule VzBeam.Commands.New do
  @moduledoc "Create a clone, restore macOS, or install OpenBSD interactively from an ISO."
  alias VzBeam.{
    Home,
    Manifest,
    Pidfile,
    Cache,
    Defaults,
    Disk,
    GuestPolicy,
    IsoCache,
    PendingBundle,
    Resolution
  }

  @reserved ~w(cache keys bin run.lock)
  @gb 1024 * 1024 * 1024

  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          image: :string,
          iso: :string,
          cpu: :integer,
          mem_gb: :integer,
          disk_gb: :integer,
          ssh_user: :string,
          resolution: :string
        ]
      )

    if invalid != [] do
      {:error, 2, "new: unknown option\n"}
    else
      with :ok <- validate_sizing(opts),
           :ok <- validate_ssh_user_option(opts[:ssh_user]),
           :ok <- validate_resolution(opts[:resolution]) do
        case {positional, opts[:image], opts[:iso]} do
          {[name, base], nil, nil} ->
            with :ok <- reject_iso_only_options(opts) do
              clone(name, base, opts, deps)
            else
              input -> input_error(input)
            end

          {[name], image, nil} when is_binary(image) ->
            with :ok <- reject_iso_only_options(opts) do
              restore(name, image, opts, deps)
            else
              input -> input_error(input)
            end

          {[name], nil, iso} when is_binary(iso) ->
            install_openbsd(name, iso, opts, deps)

          {_, image, iso} when is_binary(image) and is_binary(iso) ->
            {:error, 2, "new: --image and --iso are mutually exclusive\n"}

          {[_, _], nil, iso} when is_binary(iso) ->
            {:error, 2, "new: --iso is mutually exclusive with a base\n"}

          {[_, _], image, nil} when is_binary(image) ->
            {:error, 2, "new: --image is mutually exclusive with a base\n"}

          _ ->
            usage()
        end
      else
        input -> input_error(input)
      end
    end
  end

  defp usage do
    {:error, 2,
     "usage: vzbeam new <name> <base> | new <name> --image <latest|PATH|URL|BUILD> | new <name> --iso PATH\n"}
  end

  defp reject_iso_only_options(opts) do
    if opts[:ssh_user] || opts[:resolution],
      do: {:error, :iso_only_option},
      else: :ok
  end

  defp validate_ssh_user_option(nil), do: :ok
  defp validate_ssh_user_option(user), do: validate_ssh_user(user)

  defp validate_ssh_user(user) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_-]{0,30}\z/, user) and user != "root",
      do: :ok,
      else: {:error, :bad_ssh_user}
  end

  defp validate_resolution(nil), do: :ok

  defp validate_resolution(value) do
    case Resolution.parse(value) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_sizing(opts) do
    cond do
      is_integer(opts[:cpu]) and opts[:cpu] < 1 -> {:error, :bad_cpu}
      is_integer(opts[:mem_gb]) and opts[:mem_gb] < 1 -> {:error, :bad_mem}
      is_integer(opts[:disk_gb]) and opts[:disk_gb] < 1 -> {:error, :bad_disk}
      true -> :ok
    end
  end

  defp input_error({:error, :bad_cpu}), do: {:error, 2, "new: --cpu must be >= 1\n"}
  defp input_error({:error, :bad_mem}), do: {:error, 2, "new: --mem-gb must be >= 1\n"}
  defp input_error({:error, :bad_disk}), do: {:error, 2, "new: --disk-gb must be >= 1\n"}
  defp input_error({:error, :bad_ssh_user}), do: {:error, 2, "new: invalid --ssh-user\n"}
  defp input_error({:error, :bad_resolution}), do: {:error, 2, "new: invalid --resolution\n"}

  defp input_error({:error, :iso_only_option}),
    do: {:error, 2, "new: --ssh-user and --resolution require --iso\n"}

  # --- clone ---------------------------------------------------------------
  defp clone(name, base, opts, deps) do
    with :ok <- validate_name(name),
         {:ok, base_m} <- Manifest.read_or(base, :no_such_base),
         :ok <- refute_running(base),
         :ok <- refute_exists(name),
         {:ok, claim} <- claim_pending(name, deps) do
      complete_claim(claim, deps, fn ->
        with :ok <- copy_bundle_contents(Home.bundle_dir(base), claim.path),
             :ok <- maybe_grow_disk(claim.path, opts[:disk_gb]),
             guest = GuestPolicy.guest(base_m),
             {:ok, ids} <- deps.reid.(guest),
             :ok <-
               write_manifest(
                 claim.path,
                 clone_manifest(base_m, name, base, ids, opts)
               ) do
          {:ok,
           [
             "created ",
             name,
             " (clone of ",
             base,
             override_note(opts),
             ")\n"
             | clone_disk_note(base_m, opts)
           ]}
        end
      end)
    else
      err -> error(err)
    end
  end

  defp clone_manifest(base_m, name, base, ids, opts) do
    base_m
    |> Map.merge(%{
      "name" => name,
      "base" => base,
      "machineIdentifier" => ids.machine_identifier,
      "macAddress" => ids.mac_address,
      "createdAt" => now()
    })
    |> maybe_put("cpuCount", opts[:cpu])
    |> maybe_put("memoryBytes", opts[:mem_gb] && opts[:mem_gb] * @gb)
  end

  defp maybe_put(m, _key, nil), do: m
  defp maybe_put(m, key, val), do: Map.put(m, key, val)

  defp maybe_grow_disk(_pending, nil), do: :ok
  defp maybe_grow_disk(pending, gb), do: Disk.grow(Path.join(pending, "disk.img"), gb * @gb)

  defp clone_disk_note(manifest, opts) do
    if opts[:disk_gb],
      do: clone_disk_note(GuestPolicy.disk_growth_note(manifest)),
      else: []
  end

  defp clone_disk_note(:macos_recovery_partition) do
    [
      "note: a clone inherits its base's partition layout -- the extra space cannot\n",
      "extend the guest's root volume (recoveryOS sits in the way); use it as a new\n",
      "APFS volume, or restore fresh with --disk-gb for a full-size root.\n"
    ]
  end

  defp clone_disk_note(:openbsd_unallocated_space) do
    [
      "note: the cloned host image grew, leaving unallocated guest space. Use OpenBSD\n",
      "disk and filesystem tools inside the guest to partition and grow into it.\n"
    ]
  end

  defp override_note(opts) do
    notes =
      [
        opts[:cpu] && "cpu=#{opts[:cpu]}",
        opts[:mem_gb] && "mem=#{opts[:mem_gb]}G",
        opts[:disk_gb] && "disk=#{opts[:disk_gb]}G"
      ]
      |> Enum.filter(& &1)

    if notes == [], do: [], else: [", ", Enum.join(notes, " ")]
  end

  # --- restore -------------------------------------------------------------
  defp restore(name, spec, opts, deps) do
    disk_bytes = Defaults.resolve(opts[:disk_gb], :disk_gb) * @gb
    cpu = Defaults.resolve(opts[:cpu], :cpu)
    mem_bytes = Defaults.resolve(opts[:mem_gb], :mem_gb) * @gb

    with :ok <- validate_name(name),
         :ok <- refute_exists(name),
         {:ok, status, entry} <- deps.ensure.(spec),
         :ok <- announce_image(deps, status, entry),
         {:ok, claim} <- claim_pending(name, deps) do
      complete_claim(claim, deps, fn ->
        with :ok <- Disk.create_sparse(Path.join(claim.path, "disk.img"), disk_bytes),
             {:ok, r} <-
               deps.restore.(
                 %{
                   ipsw: Path.join(Cache.dir(), entry["file"]),
                   disk: Path.join(claim.path, "disk.img"),
                   aux: Path.join(claim.path, "aux.img"),
                   disk_size: disk_bytes,
                   cpu: cpu,
                   mem: mem_bytes
                 },
                 restore_reporter(deps)
               ),
             :ok <-
               write_manifest(
                 claim.path,
                 restore_manifest(name, entry, r, cpu, mem_bytes)
               ) do
          {:ok,
           [
             "created ",
             name,
             " (cpu=#{cpu} mem=#{div(mem_bytes, @gb)}G disk=#{div(disk_bytes, @gb)}G)\n"
           ]}
        end
      end)
    else
      err -> error(err)
    end
  end

  defp restore_manifest(name, entry, r, cpu, mem_bytes) do
    %{
      "schemaVersion" => 2,
      "guestOS" => "macos",
      "name" => name,
      "base" => nil,
      "image" => %{
        "version" => entry["version"],
        "build" => entry["build"],
        "source" => entry["source"]
      },
      "machineIdentifier" => r.machine_identifier,
      "hardwareModel" => r.hardware_model,
      "macAddress" => r.mac_address,
      "cpuCount" => cpu,
      "memoryBytes" => mem_bytes,
      "createdAt" => now()
    }
  end

  # --- interactive OpenBSD install ----------------------------------------
  defp install_openbsd(name, spec, opts, deps) do
    disk_bytes = Defaults.resolve(opts[:disk_gb], :disk_gb) * @gb
    cpu = Defaults.resolve(opts[:cpu], :cpu)
    mem_bytes = Defaults.resolve(opts[:mem_gb], :mem_gb) * @gb
    ssh_user = Defaults.resolve(opts[:ssh_user], :ssh_user)
    resolution = Defaults.resolve(opts[:resolution], :resolution)

    with :ok <- validate_name(name),
         :ok <- refute_exists(name),
         {:ok, status, entry} <- deps.ensure_iso.(spec),
         :ok <- announce_iso(deps, status, entry),
         :ok <- announce_openbsd_instructions(deps, ssh_user),
         {:ok, claim} <- claim_pending(name, deps) do
      complete_claim(claim, deps, fn ->
        disk = Path.join(claim.path, "disk.img")
        nvram = Path.join(claim.path, "nvram.bin")

        with :ok <- Disk.create_sparse(disk, disk_bytes),
             {:ok, result} <-
               deps.install.(
                 %{
                   iso: Path.join(IsoCache.dir(), entry["file"]),
                   disk: disk,
                   nvram: nvram,
                   cpu: cpu,
                   mem: mem_bytes,
                   resolution: resolution
                 },
                 install_reporter(deps)
               ) do
          manifest = openbsd_manifest(name, entry, result, ssh_user, cpu, mem_bytes)

          # The installer has powered off: the disk now holds the user's interactive
          # install, so a failure from here is tagged for preservation, not cleanup.
          with :ok <- require_file(nvram, :missing_nvram),
               :ok <- write_manifest(claim.path, manifest) do
            {:ok,
             [
               "created ",
               name,
               " (OpenBSD #{entry["version"] || "ISO"}; cpu=#{cpu} mem=#{div(mem_bytes, @gb)}G disk=#{div(disk_bytes, @gb)}G)\n"
             ]}
          else
            {:error, reason} -> {:error, {:installed, reason, manifest}}
          end
        end
      end)
    else
      err -> error(err)
    end
  end

  defp openbsd_manifest(name, entry, result, ssh_user, cpu, mem_bytes) do
    %{
      "schemaVersion" => 2,
      "guestOS" => "openbsd",
      "name" => name,
      "base" => nil,
      "image" => entry,
      "machineIdentifier" => result.machine_identifier,
      "macAddress" => result.mac_address,
      "sshUser" => ssh_user,
      "cpuCount" => cpu,
      "memoryBytes" => mem_bytes,
      "createdAt" => now()
    }
  end

  defp announce_iso(deps, status, entry) do
    verb = if status == :fetched, do: "retained", else: "using cached"
    deps.progress.([verb, " ISO ", entry["file"], "\n"])
    :ok
  end

  defp announce_openbsd_instructions(deps, ssh_user) do
    deps.progress.([
      "\n",
      "In the OpenBSD installer:\n",
      "  1. Install onto the VirtIO disk, create the user `",
      ssh_user,
      "`, and leave sshd enabled.\n",
      "  2. At \"Exit to (S)hell, (H)alt or (R)eboot?\", answer `s`, then run `halt -p`.\n",
      "     The installer's own (H)alt does not power off, so vzbeam would keep waiting.\n",
      "\n",
      "The bundle is created once the installer VM powers off. Closing the installer\n",
      "window only hides it: switch back to `vz` (Dock or Cmd-Tab) to reopen it.\n",
      "Press Ctrl-C here to cancel the install.\n",
      "\n"
    ])

    :ok
  end

  defp install_reporter(deps) do
    fn
      {:event, "install_started", _} -> deps.progress.("OpenBSD installer started.\n")
      {:event, "installed", _} -> deps.progress.("OpenBSD installer stopped; finalizing.\n")
      _ -> :ok
    end
  end

  defp require_file(path, reason) do
    if File.regular?(path), do: :ok, else: {:error, reason}
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
      String.ends_with?(n, ".pending") -> {:error, :pending_name}
      n in @reserved -> {:error, :reserved_name}
      n == "" or n in [".", ".."] or String.contains?(n, ["/", "\\"]) -> {:error, :bad_name}
      true -> :ok
    end
  end

  defp refute_running(base),
    do: if(Pidfile.running?(base), do: {:error, :base_running}, else: :ok)

  defp refute_exists(name) do
    case File.lstat(Home.bundle_dir(name)) do
      {:error, :enoent} -> :ok
      _ -> {:error, :exists}
    end
  end

  defp claim_pending(name, deps) do
    case deps.claim_pending.(name) do
      {:error, :pending_owner_unreadable} ->
        {:error, {:pending_owner_unreadable, name}}

      result ->
        result
    end
  end

  defp complete_claim(claim, deps, work) do
    case work.() do
      {:ok, output} ->
        case deps.promote_pending.(claim) do
          :ok -> {:ok, output}
          {:error, reason} -> preserve_after_promote_error(claim, reason)
        end

      {:error, {:installed, reason, manifest}} ->
        error(
          {:error,
           {:install_unfinished, claim.path, Home.bundle_dir(claim.name), reason, manifest}}
        )

      {:error, _} = work_error ->
        cleanup_after_error(claim, deps, work_error)
    end
  end

  defp cleanup_after_error(claim, deps, original_error) do
    case deps.cleanup_pending.(claim) do
      :ok -> error(original_error)
      {:error, _} = cleanup_error -> error(cleanup_error)
    end
  end

  defp preserve_after_promote_error(claim, reason) do
    final = Home.bundle_dir(claim.name)

    location =
      if File.exists?(claim.path),
        do: claim.path,
        else: final

    error({:error, {:promotion_failed, location, final, reason}})
  end

  defp copy_bundle_contents(base_dir, pending_dir) do
    with {:ok, entries} <- File.ls(base_dir) do
      entries
      |> Enum.reject(&(&1 == "install-owner.json"))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case cp_rc(Path.join(base_dir, entry), pending_dir) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp cp_rc(src, dst) do
    case System.cmd("cp", ["-Rc", src, dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:clone_failed, String.trim(out)}}
    end
  end

  defp write_manifest(dir, map) do
    Manifest.write_to(Path.join(dir, "config.json"), map)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp error({:error, :reserved_name}), do: {:error, 1, "new: name is reserved\n"}

  defp error({:error, :pending_name}),
    do: {:error, 2, "new: names ending in .pending are reserved\n"}

  defp error({:error, :bad_name}), do: {:error, 1, "new: invalid name\n"}
  defp error({:error, :no_such_base}), do: {:error, 1, "new: no such base\n"}
  defp error({:error, :base_running}), do: {:error, 1, "new: base is running; stop it first\n"}
  defp error({:error, :exists}), do: {:error, 1, "new: bundle already exists\n"}

  defp error({:error, :creation_in_progress}),
    do: {:error, 1, "new: creation already in progress\n"}

  defp error({:error, {:pending_owner_unreadable, name}}) do
    path = Home.bundle_dir(name) <> ".pending"

    {:error, 1,
     [
       "new: ",
       path,
       " has no readable install owner; verify no old `vzbeam new` is running before removing it\n"
     ]}
  end

  defp error({:error, :owner_mismatch}),
    do: {:error, 1, "new: pending bundle ownership changed; refusing to modify it\n"}

  defp error({:error, :lock_timeout}),
    do: {:error, 1, "new: another vzbeam operation holds the host lock; retry\n"}

  defp error({:error, :lock_corrupt}),
    do: {:error, 1, "new: the host lock is unreadable; inspect it before retrying\n"}

  defp error({:error, {:incompatible, have, want}}),
    do:
      {:error, 1,
       [
         "new: sidecar protocol ",
         to_string(have),
         " is incompatible with required protocol ",
         to_string(want),
         "; rebuild it (`mix vz.build`)\n"
       ]}

  defp error({:error, :not_regular}),
    do: {:error, 1, "new: ISO path is missing or not a regular file\n"}

  defp error({:error, :empty_iso}), do: {:error, 1, "new: ISO is empty\n"}
  defp error({:error, :not_local_file}), do: {:error, 1, "new: ISO must be a local file\n"}

  defp error({:error, :source_changed}),
    do: {:error, 1, "new: ISO changed while it was being retained; retry\n"}

  defp error({:error, {:copy_failed, reason}}),
    do: {:error, 1, ["new: could not retain ISO: ", reason, "\n"]}

  defp error({:error, {:promotion_failed, location, final, reason}}),
    do:
      {:error, 1,
       [
         "new: could not finalize the bundle (",
         inspect(reason),
         "); completed data was preserved at ",
         location,
         ". Do not rerun `vzbeam new` for this name. After resolving the reported ",
         "problem and confirming no creation process is active, move the preserved ",
         "directory to ",
         final,
         " if needed, then remove ",
         Path.join(final, "install-owner.json"),
         ".\n"
       ]}

  # config.json holds the install's generated identity, which exists nowhere else once
  # this process exits, so print it for the user to save by hand.
  defp error({:error, {:install_unfinished, location, final, reason, manifest}}) do
    config =
      case Manifest.encode(manifest) do
        {:ok, body} -> [body, "\n"]
        {:error, _} -> []
      end

    {:error, 1,
     [
       "new: the OpenBSD installation finished, but its bundle could not be completed (",
       inspect(reason),
       "); the installed disk was preserved at ",
       location,
       ". Do not rerun `vzbeam new` for this name. After resolving the reported problem ",
       "and confirming no creation process is active, save the config below as ",
       Path.join(location, "config.json"),
       ", move the preserved directory to ",
       final,
       ", then remove ",
       Path.join(final, "install-owner.json"),
       ".\n",
       config
     ]}
  end

  defp error({:error, {:vz, _domain, 130, message}}),
    do: {:error, 1, ["new: ", message, "\n"]}

  defp error({:error, {:vz, _domain, _code, message}}),
    do: {:error, 1, ["new: ", message, "\n"]}

  defp error({:error, :missing_nvram}),
    do: {:error, 1, "new: installer did not create nvram.bin\n"}

  defp error({:error, :invalid_manifest}), do: manifest_error(:invalid_manifest)
  defp error({:error, {:unsupported_schema, _} = reason}), do: manifest_error(reason)
  defp error({:error, {:unsupported_guest, _} = reason}), do: manifest_error(reason)

  defp error({:error, {:pending_cleanup, _file, _reason}}),
    do: {:error, 1, "new: could not clear a stale .pending dir\n"}

  defp error({:error, {:shrink, have}}),
    do: {:error, 1, ["new: --disk-gb must be >= the base disk (", Disk.gb(have), ")\n"]}

  defp error({:error, reason}), do: {:error, 1, ["new failed: ", inspect(reason), "\n"]}

  defp manifest_error(reason), do: {:error, 1, ["new: ", Manifest.describe_error(reason), "\n"]}

  defp default_deps,
    do: %{
      reid: &VzBeam.Sidecar.reid/1,
      ensure: &Cache.ensure/1,
      restore: &VzBeam.Sidecar.restore/2,
      ensure_iso: &IsoCache.ensure/1,
      install: &VzBeam.Sidecar.install/2,
      claim_pending: &PendingBundle.claim/1,
      cleanup_pending: &PendingBundle.cleanup/1,
      promote_pending: &PendingBundle.promote/1,
      progress: &default_progress/1
    }
end
