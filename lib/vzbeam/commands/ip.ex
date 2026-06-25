defmodule VzBeam.Commands.Ip do
  @moduledoc "ip <name> — resolve a bundle's IP from DHCP leases."
  alias VzBeam.{Manifest, Leases}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, &VzBeam.Leases.read/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([name], read_leases) do
    with {:ok, %{"macAddress" => mac}} when is_binary(mac) <- Manifest.read(name),
         ip when is_binary(ip) <- Leases.lookup_ip(read_leases.(), mac) do
      {:ok, [ip, "\n"]}
    else
      nil -> {:error, 1, ["ip: no DHCP lease yet for ", name, " (is it networked? bridge100)\n"]}
      {:error, _} -> {:error, 1, ["no such bundle: ", name, "\n"]}
      _ -> {:error, 1, ["bundle ", name, " has no macAddress\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ip <name>\n"}
end
