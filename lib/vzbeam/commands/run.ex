defmodule VzBeam.Commands.Run do
  @moduledoc "run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path] — boot a VM (detached)."
  alias VzBeam.{Home, Manifest, Pidfile, Defaults, Keys, Share, Sidecar, Daemon, Lock, Protocol}

  @handshake_ms 60_000
  @poll_ms 100

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run(args, deps) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [gui: :boolean, headless: :boolean, resolution: :string, share: :string])

    case positional do
      [name] -> start(name, opts, deps)
      _ -> {:error, 2, "usage: vzbeam run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]\n"}
    end
  end

  defp start(name, opts, deps) do
    with {:ok, m} <- read_manifest(name),
         :ok <- refute_running(name),
         {:ok, share} <- parse_share(opts[:share]),
         {:ok, _keys} <- Keys.ensure(),
         {:ok, vz} <- Sidecar.locate(),
         :ok <- Sidecar.check_version() do
      run_log = Path.join(Home.bundle_dir(name), "run.log")
      argv = build_argv(vz, name, m, opts, share)

      case launch(name, argv, run_log, deps) do
        {:ok, pid} -> finish(name, pid, run_log)
        {:spawn_exited, pid} -> classify_failure(name, pid, run_log)
        {:error, reason} -> error({:error, reason})
      end
    else
      err -> error(err)
    end
  end

  defp launch(name, argv, run_log, deps) do
    File.mkdir_p!(Home.bundle_dir(name))

    result =
      deps.with_lock.(fn ->
        if count_running() >= 2 do
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
  def count_running, do: Enum.count(Home.bundles(), &Pidfile.running?/1)

  defp finish(name, pid, run_log) do
    case await_started(run_log, pid, @handshake_ms) do
      {:ok, _} ->
        {:ok, ["started ", name, " (pid ", Integer.to_string(pid),
               ") — networking; try `vzbeam ip ", name, "` or `vzbeam ssh ", name, "`\n"]}

      {:error, _reason} = err ->
        cleanup(name, pid)
        started_error(err, run_log)
    end
  end

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
    body = case File.read(run_log) do
      {:ok, b} -> b
      _ -> ""
    end

    lines = String.split(body, "\n")
    complete = if body == "" or String.ends_with?(body, "\n"), do: lines, else: Enum.drop(lines, -1)

    complete
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Protocol.decode_line/1)
    |> Enum.filter(&match?({:event, _, _}, &1))
  end

  defp started?(events), do: Enum.any?(events, &match?({:event, "started", _}, &1))

  defp alive?(pid), do: match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true))

  defp classify_failure(name, pid, run_log) do
    cleanup(name, pid)
    events = read_events(run_log)

    case Enum.find(events, &match?({:event, "error", _}, &1)) do
      {:event, "error", m} ->
        {:error, 1, ["run failed: VZError ", to_string(m["code"]), " ", to_string(m["message"]), "\n"]}

      _ ->
        {:error, 1, ["run failed: sidecar exited during startup; see ", run_log, "\n"]}
    end
  end

  defp cleanup(name, pid) do
    if alive?(pid), do: System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    File.rm(Pidfile.path(name))
  end

  defp build_argv(vz, name, m, opts, share) do
    bundle = Home.bundle_dir(name)
    [vz, "run",
     "--machine-id", m["machineIdentifier"], "--hardware-model", m["hardwareModel"], "--mac", m["macAddress"],
     "--disk", Path.join(bundle, "disk.img"), "--aux", Path.join(bundle, "aux.img"),
     "--cpu", to_string(m["cpuCount"]), "--mem", to_string(m["memoryBytes"]),
     mode_flag(opts), "--resolution", Defaults.resolve(opts[:resolution], :resolution)] ++ share_args(share)
  end

  defp mode_flag(opts), do: if(opts[:gui], do: "--gui", else: "--headless")
  defp share_args(nil), do: []
  defp share_args(%{tag: t, path: p}), do: ["--share", t, p]

  defp read_manifest(name) do
    case Manifest.read(name) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, :no_such_bundle}
    end
  end

  defp refute_running(name), do: if(Pidfile.running?(name), do: {:error, :already_running}, else: :ok)
  defp parse_share(nil), do: {:ok, nil}
  defp parse_share(spec), do: Share.parse(spec)

  defp started_error({:error, {:vz, _d, code, msg}}, _log),
    do: {:error, 1, ["run failed: VZError ", to_string(code), " ", to_string(msg), "\n"]}

  defp started_error({:error, :timeout}, log),
    do: {:error, 1, ["run timed out waiting for startup; see ", log, "\n"]}

  defp started_error({:error, :exited_early}, log),
    do: {:error, 1, ["run failed: VM exited during startup; see ", log, "\n"]}

  defp error({:error, :no_such_bundle}), do: {:error, 1, "run: no such bundle\n"}
  defp error({:error, :already_running}), do: {:error, 1, "run: already running\n"}
  defp error({:error, :at_capacity}), do: {:error, 1, "run: at capacity (2 VMs already running); stop one first\n"}
  defp error({:error, :lock_timeout}), do: {:error, 1, ["run: another `vzbeam run` is in progress; retry\n"]}
  defp error({:error, :lock_corrupt}), do: {:error, 1, ["run: ", VzBeam.Lock.path(), " is unreadable; remove it if stale\n"]}
  defp error({:error, :not_found}), do: {:error, 1, "run: sidecar not found; build it (`vzbeam build-sidecar`)\n"}
  defp error({:error, :no_equals}), do: {:error, 2, "run: --share must be tag=/path\n"}
  defp error({:error, :empty_tag}), do: {:error, 2, "run: --share tag is empty\n"}
  defp error({:error, :tag_too_long}), do: {:error, 2, "run: --share tag exceeds 36 bytes\n"}
  defp error({:error, :no_such_dir}), do: {:error, 2, "run: --share host dir does not exist\n"}
  defp error({:error, reason}), do: {:error, 1, ["run failed: ", inspect(reason), "\n"]}

  defp default_deps, do: %{with_lock: &Lock.with_lock/1, spawn: &Daemon.spawn_detached/2}
end
