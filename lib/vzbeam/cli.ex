defmodule VzBeam.CLI do
  @moduledoc "Entry point: parse argv, dispatch to a verb, return {:ok|:error}."

  @usage """
  Usage: vzbeam <command> [args]

  Commands:
    ls                 list VM bundles
    ip <name>          print a VM's IP (from DHCP leases)
    fetch <latest|PATH> download/cache a restore image
  """

  @spec main([String.t()]) :: no_return
  def main(argv) do
    case run(argv) do
      {:ok, out} -> IO.write(out)
      {:error, code, out} -> IO.write(:stderr, out); System.halt(code)
    end
  end

  @spec run([String.t()]) :: {:ok, iodata} | {:error, non_neg_integer, iodata}
  def run([]), do: {:error, 2, @usage}
  def run(["--help"]), do: {:ok, @usage}
  def run(["help"]), do: {:ok, @usage}
  def run(["ip" | rest]), do: VzBeam.Commands.Ip.run(rest)
  def run(["ls" | rest]), do: VzBeam.Commands.Ls.run(rest)
  def run(["fetch" | rest]), do: VzBeam.Commands.Fetch.run(rest)
  def run([verb | _]), do: {:error, 2, ["unknown command: ", verb, "\n", @usage]}
end
