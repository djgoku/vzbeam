defmodule VzBeam.Commands.Ssh do
  @moduledoc "ssh <name> [-- cmd…] — key-based ssh; interactive shell (Port :nouse_stdio) or one-shot command."
  alias VzBeam.{Manifest, Keys, Leases, SshConn}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name | rest], deps) do
    with {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- SshConn.resolve_ip(m, deps.leases.()) do
      base = SshConn.args(ip)

      case rest do
        ["--" | cmd] when cmd != [] -> oneshot(base ++ cmd, deps)
        [] -> interactive(base, deps)
        _ -> {:error, 2, "usage: vzbeam ssh <name> [-- cmd…]\n"}
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ssh <name> [-- cmd…]\n"}

  defp oneshot(args, deps) do
    case deps.run_cmd.(args) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, status, out}
    end
  end

  defp interactive(args, deps) do
    case deps.interactive.(args) do
      0 -> {:ok, ""}
      status -> {:error, status, ""}
    end
  end

  @doc false
  def interactive_port(args) do
    ssh = System.find_executable("ssh")
    port = Port.open({:spawn_executable, ssh}, [:nouse_stdio, :exit_status, args: args])

    receive do
      {^port, {:exit_status, s}} -> s
    end
  end

  defp error({:error, :no_such_bundle}), do: {:error, 1, "ssh: no such bundle\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "ssh: no DHCP lease yet (is it networked? bridge100)\n"}
  defp error({:error, reason}), do: {:error, 1, ["ssh failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{leases: &Leases.read/0,
      run_cmd: fn args -> System.cmd("ssh", args, stderr_to_stdout: false) end,
      interactive: &interactive_port/1}
  end
end
