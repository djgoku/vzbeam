defmodule VzBeam.SshConn do
  @moduledoc "Shared SSH connection helpers: option args + lease IP resolution."
  alias VzBeam.{Keys, Leases, Defaults}

  @spec args(String.t()) :: [String.t()]
  def args(ip) do
    ["-i", Keys.private(), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
     "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
     "#{Defaults.values().ssh_user}@#{ip}"]
  end

  @spec resolve_ip(map, String.t()) :: {:ok, String.t()} | {:error, :no_lease}
  def resolve_ip(manifest, leases) do
    case Leases.lookup_ip(leases, manifest["macAddress"]) do
      nil -> {:error, :no_lease}
      ip -> {:ok, ip}
    end
  end
end
