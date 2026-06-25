defmodule VzBeam.Leases do
  @moduledoc "Pure parser for /var/db/dhcpd_leases."

  @spec path() :: Path.t()
  def path, do: "/var/db/dhcpd_leases"

  @spec read() :: String.t()
  def read do
    case File.read(path()) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  @spec parse(String.t()) :: [%{mac: String.t(), ip: String.t() | nil, name: String.t() | nil}]
  def parse(content) do
    content
    |> String.split("}")
    |> Enum.map(&parse_block/1)
    |> Enum.reject(&is_nil(&1.mac))
  end

  @spec lookup_ip(String.t(), String.t()) :: String.t() | nil
  def lookup_ip(content, mac) do
    want = normalize_mac(mac)

    content
    |> parse()
    |> Enum.find_value(fn e -> if normalize_mac(e.mac) == want, do: e.ip end)
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

  # macOS writes /var/db/dhcpd_leases MACs with leading zeros stripped per octet
  # (e.g. `5e:a:b:0:cd:ef`), while our config MAC is canonical (`5e:0a:0b:00:cd:ef`).
  # Normalize both to lowercase, zero-padded octets so they compare equal.
  defp normalize_mac(nil), do: nil
  defp normalize_mac(mac) do
    mac
    |> String.downcase()
    |> String.split(":")
    |> Enum.map_join(":", &String.pad_leading(&1, 2, "0"))
  end
end
