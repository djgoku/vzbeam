defmodule VzBeam.Leases do
  @moduledoc "Pure parser for /var/db/dhcpd_leases."

  @spec path() :: Path.t()
  def path, do: "/var/db/dhcpd_leases"

  @spec parse(String.t()) :: [%{mac: String.t(), ip: String.t() | nil, name: String.t() | nil}]
  def parse(content) do
    content
    |> String.split("}")
    |> Enum.map(&parse_block/1)
    |> Enum.reject(&is_nil(&1.mac))
  end

  @spec lookup_ip(String.t(), String.t()) :: String.t() | nil
  def lookup_ip(content, mac) do
    want = String.downcase(mac)

    content
    |> parse()
    |> Enum.find_value(fn e -> if e.mac == want, do: e.ip end)
  end

  defp parse_block(block) do
    %{
      mac: extract(block, ~r/hw_address=\d+,([0-9a-fA-F:]+)/) |> downcase(),
      ip: extract(block, ~r/ip_address=([0-9.]+)/),
      name: extract(block, ~r/name=([^\s]+)/)
    }
  end

  defp extract(block, regex) do
    case Regex.run(regex, block) do
      [_, captured] -> captured
      _ -> nil
    end
  end

  defp downcase(nil), do: nil
  defp downcase(s), do: String.downcase(s)
end
