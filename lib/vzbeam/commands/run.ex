defmodule VzBeam.Commands.Run do
  @moduledoc "Boot a VM, optionally attaching OpenBSD recovery media for one run."
  alias VzBeam.{
    Home,
    Manifest,
    Pidfile,
    Defaults,
    Keys,
    Share,
    Sidecar,
    Daemon,
    Lock,
    Protocol,
    GuestPolicy,
    IsoCache,
    RunOptions
  }

  @handshake_ms 60_000
  @poll_ms 100

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    case RunOptions.parse(args) do
      {:ok, opts} -> start(opts, deps)
      {:error, reason} -> options_error(reason)
    end
  end

  defp start(%{name: name} = opts, deps) do
    with {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- refute_running(name),
         :ok <- validate_policy(m, opts),
         {:ok, share} <- parse_share(opts.share),
         {:ok, iso} <- resolve_media(m, opts.iso),
         :ok <- validate_guest_files(name, m),
         {:ok, _keys} <- Keys.ensure(),
         {:ok, vz} <- Sidecar.locate(),
         :ok <- Sidecar.check_version(vz) do
      run_log = Path.join(Home.bundle_dir(name), "run.log")
      argv = build_argv(vz, name, m, opts, share, iso)

      case launch(name, m, argv, run_log, deps) do
        {:ok, pid} -> finish(name, pid, run_log, opts.gui)
        {:spawn_exited, pid} -> classify_failure(name, pid, run_log)
        {:error, reason} -> error({:error, reason})
      end
    else
      err -> error(err)
    end
  end

  defp launch(name, manifest, argv, run_log, deps) do
    File.mkdir_p!(Home.bundle_dir(name))

    result =
      deps.with_lock.(fn ->
        if GuestPolicy.consumes_macos_slot?(manifest) and count_running() >= 2 do
          {:error, :at_capacity}
        else
          case deps.spawn.(argv, run_log) do
            {:ok, pid} ->
              case Pidfile.write(name, pid) do
                :ok -> {:ok, pid}
                {:error, :process_not_found} -> {:spawn_exited, pid}
              end

            {:error, _} = err ->
              err
          end
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, lock_err} -> {:error, lock_err}
    end
  end

  @spec count_running() :: non_neg_integer
  def count_running do
    Enum.count(Home.bundles(), fn name ->
      Pidfile.running?(name) and
        case Manifest.read(name) do
          {:ok, manifest} -> GuestPolicy.consumes_macos_slot?(manifest)
          {:error, _} -> false
        end
    end)
  end

  defp finish(name, pid, run_log, gui) do
    case await_started(run_log, pid, @handshake_ms) do
      {:ok, _} ->
        {:ok,
         [
           "started ",
           name,
           " (pid ",
           Integer.to_string(pid),
           ") - networking; try `vzbeam ip ",
           name,
           "` or `vzbeam ssh ",
           name,
           "`\n",
           gui_hint(name, gui)
         ]}

      {:error, _reason} = err ->
        cleanup(name, pid)
        started_error(err, run_log)
    end
  end

  # The window's close button only hides it; the sidecar reopens it when its app is reactivated.
  defp gui_hint(_name, false), do: []

  defp gui_hint(name, true),
    do: [
      "closing the window leaves ",
      name,
      " running: switch back to `vz` (Dock or Cmd-Tab) to reopen it; `vzbeam stop ",
      name,
      "` shuts it down\n"
    ]

  @spec await_started(Path.t(), pos_integer, pos_integer) :: {:ok, pos_integer} | {:error, term}
  def await_started(run_log, pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(run_log, pid, deadline)
  end

  defp poll(run_log, pid, deadline) do
    events = read_events(run_log)
    error = Enum.find(events, &match?({:event, "error", _}, &1))

    cond do
      error ->
        {:event, "error", m} = error
        {:error, {:vz, m["domain"], m["code"], m["message"]}}

      Enum.any?(events, &match?({:event, "guest_stopped", _}, &1)) ->
        {:error, :exited_early}

      started?(events) and alive?(pid) ->
        {:ok, pid}

      started?(events) or not alive?(pid) ->
        {:error, :exited_early}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@poll_ms)
        poll(run_log, pid, deadline)
    end
  end

  defp read_events(run_log) do
    body =
      case File.read(run_log) do
        {:ok, b} -> b
        _ -> ""
      end

    lines = String.split(body, "\n")

    complete =
      if body == "" or String.ends_with?(body, "\n"), do: lines, else: Enum.drop(lines, -1)

    complete
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Protocol.decode_line/1)
    |> Enum.filter(&match?({:event, _, _}, &1))
  end

  defp started?(events), do: Enum.any?(events, &match?({:event, "started", _}, &1))

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true))

  defp classify_failure(name, pid, run_log) do
    cleanup(name, pid)
    events = read_events(run_log)

    case Enum.find(events, &match?({:event, "error", _}, &1)) do
      {:event, "error", m} ->
        vz_error(m["code"], m["message"])

      _ ->
        {:error, 1, ["run failed: sidecar exited during startup; see ", run_log, "\n"]}
    end
  end

  defp cleanup(name, pid) do
    if alive?(pid),
      do: System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

    File.rm(Pidfile.path(name))
  end

  defp build_argv(vz, name, m, opts, share, iso) do
    bundle = Home.bundle_dir(name)

    [vz, "run"] ++
      identity_args(m, bundle) ++
      [
        "--cpu",
        to_string(m["cpuCount"]),
        "--mem",
        to_string(m["memoryBytes"]),
        mode_flag(opts),
        "--resolution",
        Defaults.resolve(opts.resolution, :resolution),
        # Shown in the window title, so several open VMs can be told apart.
        "--name",
        name
      ] ++ share_args(share) ++ iso_args(iso)
  end

  defp identity_args(%{"guestOS" => "macos"} = manifest, bundle) do
    [
      "--guest",
      "macos",
      "--machine-id",
      manifest["machineIdentifier"],
      "--hardware-model",
      manifest["hardwareModel"],
      "--mac",
      manifest["macAddress"],
      "--disk",
      Path.join(bundle, "disk.img"),
      "--aux",
      Path.join(bundle, "aux.img")
    ]
  end

  defp identity_args(%{"guestOS" => "openbsd"} = manifest, bundle) do
    [
      "--guest",
      "openbsd",
      "--machine-id",
      manifest["machineIdentifier"],
      "--mac",
      manifest["macAddress"],
      "--disk",
      Path.join(bundle, "disk.img"),
      "--nvram",
      Path.join(bundle, "nvram.bin")
    ]
  end

  defp mode_flag(opts), do: if(opts.gui, do: "--gui", else: "--headless")
  defp share_args(nil), do: []
  defp share_args(%{tag: t, path: p}), do: ["--share", t, p]
  defp iso_args(nil), do: []
  defp iso_args(path), do: ["--iso", path]

  defp validate_policy(manifest, opts) do
    cond do
      opts.iso != nil and GuestPolicy.guest(manifest) == :macos ->
        {:error, :iso_macos}

      opts.share != nil and not GuestPolicy.supports_share?(manifest) ->
        {:error, :share_openbsd}

      true ->
        :ok
    end
  end

  defp resolve_media(_manifest, nil), do: {:ok, nil}
  defp resolve_media(manifest, :cached), do: IsoCache.resolve_cached(manifest)

  defp resolve_media(_manifest, {:path, path}) do
    case IsoCache.validate_one_shot(path) do
      {:ok, expanded} -> {:ok, expanded}
      {:error, reason} -> {:error, {:one_shot_iso, reason, path}}
    end
  end

  defp validate_guest_files(name, %{"guestOS" => "openbsd"}) do
    if File.regular?(Path.join(Home.bundle_dir(name), "nvram.bin")),
      do: :ok,
      else: {:error, :missing_nvram}
  end

  defp validate_guest_files(_name, %{"guestOS" => "macos"}), do: :ok

  defp refute_running(name),
    do: if(Pidfile.running?(name), do: {:error, :already_running}, else: :ok)

  defp parse_share(nil), do: {:ok, nil}
  defp parse_share(spec), do: Share.parse(spec)

  defp options_error(:mode_conflict),
    do: {:error, 2, "run: --gui and --headless are mutually exclusive\n"}

  defp options_error(:iso_headless),
    do: {:error, 2, "run: --iso cannot be used with --headless\n"}

  defp options_error(:repeated_iso),
    do: {:error, 2, "run: --iso may be specified only once\n"}

  defp options_error(:bad_resolution),
    do: {:error, 2, "run: invalid --resolution (expected WIDTHxHEIGHT)\n"}

  defp options_error(:unknown_option), do: {:error, 2, "run: unknown option\n"}

  defp options_error(:usage),
    do:
      {:error, 2,
       "usage: vzbeam run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path] [--iso [PATH]]\n"}

  defp started_error({:error, {:vz, _d, code, msg}}, _log), do: vz_error(code, msg)

  defp started_error({:error, :timeout}, log),
    do: {:error, 1, ["run timed out waiting for startup; see ", log, "\n"]}

  defp started_error({:error, :exited_early}, log),
    do: {:error, 1, ["run failed: VM exited during startup; see ", log, "\n"]}

  defp vz_error(6, _msg), do: error({:error, :at_capacity})

  defp vz_error(code, msg),
    do: {:error, 1, ["run failed: VZError ", to_string(code), " ", to_string(msg), "\n"]}

  defp error({:error, :no_such_bundle}), do: {:error, 1, "run: no such bundle\n"}
  defp error({:error, :already_running}), do: {:error, 1, "run: already running\n"}

  defp error({:error, :at_capacity}),
    do: {:error, 1, "run: at capacity (2 macOS VMs already running); stop one first\n"}

  defp error({:error, :lock_timeout}),
    do: {:error, 1, ["run: another `vzbeam run` is in progress; retry\n"]}

  defp error({:error, :lock_corrupt}),
    do: {:error, 1, ["run: ", VzBeam.Lock.path(), " is unreadable; remove it if stale\n"]}

  defp error({:error, :not_found}),
    do: {:error, 1, "run: sidecar not found; build it (`mix vz.build`)\n"}

  defp error({:error, {:incompatible, have, want}}),
    do:
      {:error, 1,
       [
         "run: sidecar protocol ",
         to_string(have),
         " is incompatible with required protocol ",
         to_string(want),
         "; rebuild it (`mix vz.build`)\n"
       ]}

  defp error({:error, :iso_macos}),
    do: {:error, 2, "run: --iso recovery is only supported for OpenBSD bundles\n"}

  defp error({:error, :share_openbsd}),
    do: {:error, 2, "run: --share is not supported for OpenBSD bundles\n"}

  defp error({:error, {:missing_cached_iso, digest}}),
    do:
      {:error, 1,
       [
         "run: cached ISO ",
         digest,
         " is missing at ",
         cached_iso_path(digest),
         "; reinstall or pass --iso PATH\n"
       ]}

  defp error({:error, {:corrupt_cached_iso, digest}}),
    do:
      {:error, 1,
       [
         "run: cached ISO ",
         digest,
         " is corrupt at ",
         cached_iso_path(digest),
         "; reinstall or pass --iso PATH\n"
       ]}

  defp error({:error, :invalid_iso_reference}),
    do: {:error, 1, "run: bundle has an invalid cached ISO reference\n"}

  defp error({:error, {:one_shot_iso, :not_regular, path}}),
    do: {:error, 1, ["run: one-shot ISO ", path, " is missing or not a regular file\n"]}

  defp error({:error, {:one_shot_iso, :empty_iso, path}}),
    do: {:error, 1, ["run: one-shot ISO ", path, " is empty\n"]}

  defp error({:error, {:one_shot_iso, :not_local_file, path}}),
    do: {:error, 1, ["run: one-shot ISO ", path, " must be a local file\n"]}

  defp error({:error, :missing_nvram}),
    do: {:error, 1, "run: OpenBSD bundle is missing nvram.bin\n"}

  defp error({:error, manifest_error})
       when manifest_error == :invalid_manifest or
              (is_tuple(manifest_error) and
                 elem(manifest_error, 0) in [:unsupported_schema, :unsupported_guest]) do
    {:error, 1, ["run: ", Manifest.describe_error(manifest_error), "\n"]}
  end

  defp error({:error, :no_equals}), do: {:error, 2, "run: --share must be tag=/path\n"}
  defp error({:error, :empty_tag}), do: {:error, 2, "run: --share tag is empty\n"}
  defp error({:error, :tag_too_long}), do: {:error, 2, "run: --share tag exceeds 36 bytes\n"}
  defp error({:error, :no_such_dir}), do: {:error, 2, "run: --share host dir does not exist\n"}
  defp error({:error, reason}), do: {:error, 1, ["run failed: ", inspect(reason), "\n"]}

  defp cached_iso_path(digest), do: Path.join(IsoCache.dir(), digest <> ".iso")

  defp default_deps, do: %{with_lock: &Lock.with_lock/1, spawn: &Daemon.spawn_detached/2}
end
