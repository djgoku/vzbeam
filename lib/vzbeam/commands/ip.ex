defmodule VzBeam.Commands.Ip do
  @moduledoc "ip <name> — resolve a bundle's IP from DHCP leases."
  alias VzBeam.{Manifest, Leases}

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run(args), do: run(args, &VzBeam.Leases.read/0)

  @spec run([String.t()], (-> String.t())) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([name], read_leases) do
    case Manifest.read(name) do
      {:ok, %{"macAddress" => mac}} when is_binary(mac) ->
        case Leases.lookup_ip(read_leases.(), mac) do
          ip when is_binary(ip) ->
            {:ok, [ip, "\n"]}

          nil ->
            {:error, 1, ["ip: no DHCP lease yet for ", name, " (is it networked? bridge100)\n"]}
        end

      {:ok, _manifest} ->
        {:error, 1, ["bundle ", name, " has no macAddress\n"]}

      {:error, :enoent} ->
        {:error, 1, ["no such bundle: ", name, "\n"]}

      {:error, :invalid_manifest} ->
        manifest_error(:invalid_manifest)

      {:error, {:unsupported_schema, _} = reason} ->
        manifest_error(reason)

      {:error, {:unsupported_guest, _} = reason} ->
        manifest_error(reason)

      {:error, reason} ->
        {:error, 1, ["ip failed: ", inspect(reason), "\n"]}
    end
  end

  def run(_, _), do: {:error, 2, "usage: vzbeam ip <name>\n"}

  defp manifest_error(reason), do: {:error, 1, ["ip: ", Manifest.describe_error(reason), "\n"]}
end
