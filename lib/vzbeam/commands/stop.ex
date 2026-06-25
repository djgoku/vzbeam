defmodule VzBeam.Commands.Stop do
  @moduledoc "stop <name> — graceful guest shutdown over SSH (sudo -n shutdown -h now)."
  alias VzBeam.{Manifest, Pidfile, Keys, Leases, SshConn}

  @reap_ms 60_000
  @poll_ms 500

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    with {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- ensure_running(name),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- SshConn.resolve_ip(m, deps.leases.()) do
      {out, _status} = deps.ssh.(SshConn.args(ip) ++ ["sudo", "-n", "shutdown", "-h", "now"])

      if sudo_needs_auth?(out) do
        {:error, 1, ["stop: graceful shutdown needs passwordless sudo on the guest (",
                     String.trim(out), "). Grant `admin` a NOPASSWD shutdown rule (see the run docs), ",
                     "or use `vzbeam kill ", name, "`.\n"]}
      else
        deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

        case Pidfile.reap(name, deadline, @poll_ms) do
          :stopped -> File.rm(Pidfile.path(name)); {:ok, ["stopped ", name, "\n"]}
          :timeout -> {:error, 1, [name, " did not stop in time; try `vzbeam kill ", name, "`\n"]}
        end
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam stop <name>\n"}

  # `sudo -n` fails fast (no password prompt) when the guest admin lacks NOPASSWD;
  # detect that so we surface an actionable error instead of waiting out the reap.
  defp sudo_needs_auth?(out) do
    String.contains?(out, "a password is required") or String.contains?(out, "a terminal is required")
  end

  defp ensure_running(name), do: if(Pidfile.running?(name), do: :ok, else: {:error, :not_running})

  defp error({:error, :no_such_bundle}), do: {:error, 1, "stop: no such bundle\n"}
  defp error({:error, :not_running}), do: {:error, 1, "stop: not running\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "stop: no DHCP lease yet (is it networked?)\n"}
  defp error({:error, reason}), do: {:error, 1, ["stop failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{ssh: fn args -> System.cmd("ssh", args, stderr_to_stdout: true) end,
      leases: &Leases.read/0, reap_ms: @reap_ms}
  end
end
