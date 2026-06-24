defmodule VzBeam.Commands.Stop do
  @moduledoc "stop <name> — graceful guest shutdown over SSH (sudo -n shutdown -h now)."
  alias VzBeam.{Manifest, Pidfile, Keys, Leases, Defaults}

  @reap_ms 60_000
  @poll_ms 500

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    with {:ok, m} <- read_manifest(name),
         :ok <- ensure_running(name),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- resolve_ip(m, deps.leases.()) do
      _ = deps.ssh.(ssh_args(ip) ++ ["sudo", "-n", "shutdown", "-h", "now"])
      deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

      case reap(name, deadline) do
        :stopped -> File.rm(Pidfile.path(name)); {:ok, ["stopped ", name, "\n"]}
        :timeout -> {:error, 1, [name, " did not stop in time; try `vzbeam kill ", name, "`\n"]}
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam stop <name>\n"}

  defp reap(name, deadline) do
    cond do
      not Pidfile.running?(name) -> :stopped
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(@poll_ms); reap(name, deadline)
    end
  end

  defp ssh_args(ip) do
    ["-i", Keys.private(), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
     "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
     "#{Defaults.values().ssh_user}@#{ip}"]
  end

  defp read_manifest(name) do
    case Manifest.read(name) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, :no_such_bundle}
    end
  end

  defp ensure_running(name), do: if(Pidfile.running?(name), do: :ok, else: {:error, :not_running})

  defp resolve_ip(m, leases) do
    case Leases.lookup_ip(leases, m["macAddress"]) do
      nil -> {:error, :no_lease}
      ip -> {:ok, ip}
    end
  end

  defp error({:error, :no_such_bundle}), do: {:error, 1, "stop: no such bundle\n"}
  defp error({:error, :not_running}), do: {:error, 1, "stop: not running\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "stop: no DHCP lease yet (is it networked?)\n"}
  defp error({:error, reason}), do: {:error, 1, ["stop failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{ssh: fn args -> System.cmd("ssh", args, stderr_to_stdout: true) end,
      leases: &Leases.read/0, reap_ms: @reap_ms}
  end
end
