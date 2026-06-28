defmodule VzBeam.CLI do
  @moduledoc "Entry point: parse argv, dispatch to a verb, return {:ok|:error}."

  # Baked in at compile time: works for both the escript (app: nil) and the
  # Burrito release, where Application.spec/2 is unreliable.
  @version Mix.Project.config()[:version]
  @repo_url "https://github.com/djgoku/vzbeam"
  @version_line "vzbeam #{@version} - #{@repo_url}"

  @usage """
  #{@version_line}

  Usage: vzbeam <command> [args]

  Commands:
    ls                 list VM bundles
    ip <name>          print a VM's IP (from DHCP leases)
    fetch <latest|PATH|URL|BUILD> download/cache a restore image
    images             list cached restore images
    new <name> <base>  clone a stopped base (CoW)
    new <name> --image <latest|PATH|URL|BUILD>  restore a fresh base
    rm <name>          delete a stopped bundle
    set <name> [--cpu N] [--mem-gb M]  change a stopped VM's CPU/RAM
    run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]  boot a VM (detached)
    stop <name>        graceful guest shutdown over SSH
    kill <name>        force power-off (SIGTERM, then SIGKILL)
    ssh <name> [-- cmd...]  ssh into a VM (interactive or one-shot)
    displays           show host display(s) + suggested --resolution values
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
  def run(["version"]), do: {:ok, @version_line <> "\n"}
  def run(["--version"]), do: {:ok, @version_line <> "\n"}
  def run(["-v"]), do: {:ok, @version_line <> "\n"}
  def run(["ip" | rest]), do: VzBeam.Commands.Ip.run(rest)
  def run(["ls" | rest]), do: VzBeam.Commands.Ls.run(rest)
  def run(["fetch" | rest]), do: VzBeam.Commands.Fetch.run(rest)
  def run(["images" | rest]), do: VzBeam.Commands.Images.run(rest)
  def run(["new" | rest]), do: VzBeam.Commands.New.run(rest)
  def run(["rm" | rest]), do: VzBeam.Commands.Rm.run(rest)
  def run(["set" | rest]), do: VzBeam.Commands.Set.run(rest)
  def run(["run" | rest]), do: VzBeam.Commands.Run.run(rest)
  def run(["stop" | rest]), do: VzBeam.Commands.Stop.run(rest)
  def run(["kill" | rest]), do: VzBeam.Commands.Kill.run(rest)
  def run(["ssh" | rest]), do: VzBeam.Commands.Ssh.run(rest)
  def run(["displays" | rest]), do: VzBeam.Commands.Displays.run(rest)
  def run([verb | _]), do: {:error, 2, ["unknown command: ", verb, "\n", @usage]}
end
