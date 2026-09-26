defmodule VzBeam.Commands.Ssh do
  @moduledoc "ssh <name> [-- cmd…] — key-based ssh (Port :nouse_stdio); interactive shell or one-shot command."
  alias VzBeam.{Manifest, Keys, Leases, SshConn}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, default_deps())

  def run([name | rest], deps) do
    with {:ok, m} <- Manifest.read_or(name, :no_such_bundle),
         {:ok, _} <- Keys.ensure(),
         {:ok, ip} <- SshConn.resolve_ip(m, deps.leases.()) do
      base = SshConn.args(ip)

      case rest do
        ["--" | cmd] when cmd != [] -> ssh(base ++ cmd, deps)
        [] -> ssh(base, deps)
        _ -> {:error, 2, "usage: vzbeam ssh <name> [-- cmd...]\n"}
      end
    else
      err -> error(err)
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ssh <name> [-- cmd...]\n"}

  # ssh writes to vzbeam's own stdin/stdout/stderr, so a one-shot command's output streams
  # byte-for-byte (binary-safe) and keeps stdout and stderr apart, even when it fails.
  defp ssh(args, deps) do
    case deps.ssh.(args) do
      0 -> {:ok, ""}
      status -> {:error, status, ""}
    end
  end

  @doc false
  def ssh_port(args, exe \\ System.find_executable("ssh")) do
    port = Port.open({:spawn_executable, exe}, [:nouse_stdio, :exit_status, args: args])

    receive do
      {^port, {:exit_status, s}} -> s
    end
  end

  defp error({:error, :no_such_bundle}), do: {:error, 1, "ssh: no such bundle\n"}
  defp error({:error, :no_lease}), do: {:error, 1, "ssh: no DHCP lease yet (is it networked? bridge100)\n"}
  defp error({:error, reason}), do: {:error, 1, ["ssh failed: ", inspect(reason), "\n"]}

  defp default_deps do
    %{leases: &Leases.read/0, ssh: &ssh_port/1}
  end
end
