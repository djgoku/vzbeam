defmodule VzBeam.CLI do
  @moduledoc "Entry point: parse argv, dispatch to a verb, return {:ok|:error}."

  @usage """
  Usage: vzbeam <command> [args]

  Commands:
    ls                 list VM bundles
    ip <name>          print a VM's IP (from DHCP leases)
    fetch <latest|PATH> download/cache a restore image
    images             list cached restore images
    new <name> <base>  clone a stopped base (CoW)
    new <name> --image <latest|PATH>  restore a fresh base
    rm <name>          delete a stopped bundle
    run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]  boot a VM (detached)
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
  def run(["images" | rest]), do: VzBeam.Commands.Images.run(rest)
  def run(["new" | rest]), do: VzBeam.Commands.New.run(rest)
  def run(["rm" | rest]), do: VzBeam.Commands.Rm.run(rest)
  def run(["run" | rest]), do: VzBeam.Commands.Run.run(rest)
  def run([verb | _]), do: {:error, 2, ["unknown command: ", verb, "\n", @usage]}
end
