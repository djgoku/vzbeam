defmodule VzBeam.Commands.Stop do
  @moduledoc "stop <name> — graceful guest-aware shutdown over SSH."
  alias VzBeam.{Manifest, Pidfile, Keys, Leases, SshConn, GuestPolicy}

  @reap_ms 60_000
  @poll_ms 500

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name], deps) do
    with {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         :ok <- ensure_running(name),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- SshConn.resolve_ip(m, deps.leases.()) do
      user = GuestPolicy.ssh_user(m)
      guest = GuestPolicy.guest(m)
      {out, status} = deps.ssh.(SshConn.args(ip, user) ++ GuestPolicy.shutdown_argv(m))

      if privilege_denied?(guest, out, status) do
        privilege_error(guest, name, user, out)
      else
        reap(name, deps)
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam stop <name>\n"}

  defp privilege_denied?(_guest, _out, 0), do: false

  defp privilege_denied?(:macos, out, _status) do
    String.contains?(out, "a password is required") or
      String.contains?(out, "a terminal is required")
  end

  defp privilege_denied?(:openbsd, out, _status) do
    String.contains?(out, "Operation not permitted") or
      String.contains?(out, "a password is required") or
      String.contains?(out, "doas is not enabled")
  end

  defp privilege_error(:macos, name, user, out) do
    {:error, 1,
     [
       "stop: graceful shutdown needs passwordless sudo configured in sudoers (",
       String.trim(out),
       "). Grant `",
       user,
       "` a NOPASSWD shutdown rule, or use `vzbeam kill ",
       name,
       "`.\n"
     ]}
  end

  defp privilege_error(:openbsd, name, user, out) do
    {:error, 1,
     [
       "stop: graceful shutdown needs /etc/doas.conf rule `permit nopass ",
       user,
       " as root cmd /sbin/shutdown args -p now` (",
       String.trim(out),
       "). Or use `vzbeam kill ",
       name,
       "`.\n"
     ]}
  end

  defp reap(name, deps) do
    deadline = System.monotonic_time(:millisecond) + Map.get(deps, :reap_ms, @reap_ms)

    case Pidfile.reap(name, deadline, @poll_ms) do
      :stopped ->
        File.rm(Pidfile.path(name))
        {:ok, ["stopped ", name, "\n"]}

      :timeout ->
        {:error, 1, [name, " did not stop in time; try `vzbeam kill ", name, "`\n"]}
    end
  end

  defp ensure_running(name), do: if(Pidfile.running?(name), do: :ok, else: {:error, :not_running})

  defp error({:error, :no_such_bundle}), do: {:error, 1, "stop: no such bundle\n"}
  defp error({:error, :not_running}), do: {:error, 1, "stop: not running\n"}

  defp error({:error, :no_lease}),
    do: {:error, 1, "stop: no DHCP lease yet (is it networked? bridge100)\n"}

  defp error({:error, :invalid_manifest}), do: manifest_error(:invalid_manifest)
  defp error({:error, {:unsupported_schema, _} = reason}), do: manifest_error(reason)
  defp error({:error, {:unsupported_guest, _} = reason}), do: manifest_error(reason)
  defp error({:error, reason}), do: {:error, 1, ["stop failed: ", inspect(reason), "\n"]}

  defp manifest_error(reason), do: {:error, 1, ["stop: ", Manifest.describe_error(reason), "\n"]}

  defp default_deps do
    %{
      ssh: fn args -> System.cmd("ssh", args, stderr_to_stdout: true) end,
      leases: &Leases.read/0,
      reap_ms: @reap_ms
    }
  end
end
