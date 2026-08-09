defmodule VzBeam.CLI do
  @moduledoc "Entry point: parse argv, dispatch to a verb, return {:ok|:error}."

  # Baked in at compile time: works for both the escript (app: nil) and the
  # Burrito release, where Application.spec/2 is unreliable.
  @version Mix.Project.config()[:version]
  @repo_url "https://github.com/djgoku/vzbeam"
  @version_line "vzbeam #{@version} - #{@repo_url}"

  # Sizing defaults surface in help text; pull them from the single source.
  @d VzBeam.Defaults.values()

  @usage """
  #{@version_line}

  Usage: vzbeam <command> [args]
         vzbeam help <command>   detailed help (same as: vzbeam <command> --help)

  Images:
    fetch <latest|PATH|URL|BUILD>  download/cache a restore image
    images                       list restore images (cached + what Apple offers)

  Bundles:
    new <name> --image <latest|PATH|URL|BUILD>  restore a fresh base
    new <name> <base>            clone a stopped base (CoW)
    set <name> [--cpu N] [--mem-gb M] [--disk-gb G]  change a stopped VM
    rm <name>                    delete a stopped bundle

  Lifecycle:
    run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]  boot a VM (detached)
    stop <name>                  graceful guest shutdown over SSH
    kill <name>                  force power-off (SIGTERM, then SIGKILL)
    ssh <name> [-- cmd...]       ssh into a VM (interactive or one-shot)

  Inspect:
    ls                           list VM bundles
    ip <name>                    print a VM's IP (from DHCP leases)
    displays                     show host display(s) + suggested --resolution values
  """

  @spec_help """
  An image <spec> is one of:
    latest    Apple's latest supported restore image
    PATH      a local .ipsw file
    URL       an https:// URL to an .ipsw (downloaded with a progress bar, cached)
    BUILD     a cached build id from `vzbeam images` (e.g. 26A5368g, case-insensitive)
  """

  @help %{
    "fetch" => """
    Usage: vzbeam fetch <latest|PATH|URL|BUILD>

    Download a macOS restore image into the cache. Every spec resolves to a
    cache entry keyed by its build, so re-fetching the same image is a no-op
    and the disk is never duplicated. An uncached BUILD is resolved through
    Apple's IPSW catalog (the remote rows of `vzbeam images`) and downloaded.

    #{@spec_help}\
    """,
    "images" => """
    Usage: vzbeam images

    One table of restore images. STATUS says where each lives:
      local    in the cache -- usable by `new --image <BUILD>` right away
      remote   offered by Apple (its IPSW catalog on mesu.apple.com) but not
               cached yet -- download with `fetch <BUILD>`

    Apple only offers builds it still signs -- the same set a VM can be
    restored from -- so the remote rows are the full fetchable menu. If the
    catalog is unreachable (offline), cached images are listed with a note.
    """,
    "new" => """
    Usage: vzbeam new <name> --image <latest|PATH|URL|BUILD>   restore a fresh base
           vzbeam new <name> <base>                            clone a stopped base (CoW)

    Flags (both forms):
      --cpu N       CPU count       (default #{@d.cpu}; a clone inherits its base)
      --mem-gb M    memory in GiB   (default #{@d.mem_gb}; a clone inherits its base)
      --disk-gb G   disk in GiB     (default #{@d.disk_gb}; a clone's disk can only grow
                    past its base -- the image is sparse, so unused space costs
                    nothing on the host)

    #{@spec_help}\
    """,
    "set" => """
    Usage: vzbeam set <name> [--cpu N] [--mem-gb M] [--disk-gb G]

    Change a stopped VM's sizing. At least one flag is required.
      --cpu N       CPU count
      --mem-gb M    memory in GiB
      --disk-gb G   grow the disk to G GiB (shrinking is refused: it would
                    truncate the guest's APFS container)

    After growing the disk, grow the guest's APFS container inside the VM
    once it boots:
      vzbeam ssh <name> -- sudo diskutil apfs resizeContainer disk0s2 0
    """,
    "rm" => """
    Usage: vzbeam rm <name>

    Delete a stopped bundle. Refuses if the VM is running; stop or kill it first.
    """,
    "run" => """
    Usage: vzbeam run <name> [--gui|--headless] [--resolution WxH] [--share tag=/path]

    Boot a VM detached; the CLI returns once the VM is up.
      --gui              open a window
      --headless         no window (the default)
      --resolution WxH   GUI resolution (default #{@d.resolution}; see `vzbeam displays`)
      --share tag=/path  share a host dir into the guest via VirtioFS (tag <= 36
                         bytes); mount it in the guest: mount_virtiofs <tag> <dir>
    """,
    "stop" => """
    Usage: vzbeam stop <name>

    Graceful guest shutdown over SSH (sudo -n shutdown -h now), then waits for
    the VM process to exit.
    """,
    "kill" => """
    Usage: vzbeam kill <name>

    Force power-off: SIGTERM to the VM's vz run pid (the sidecar traps it and
    stops the VM), SIGKILL as a last resort.
    """,
    "ssh" => """
    Usage: vzbeam ssh <name> [-- cmd...]

    SSH into the VM with vzbeam's generated key (user "#{@d.ssh_user}"). With no
    command: an interactive shell. After `--`: run a one-shot command, e.g.
      vzbeam ssh dev -- sw_vers
    """,
    "ls" => """
    Usage: vzbeam ls

    Table of bundles: NAME, STATUS, BASE, OS, IP, CPU, MEM, DISK. DISK is the
    provisioned (sparse) size of disk.img; actual host usage can be smaller.
    """,
    "ip" => """
    Usage: vzbeam ip <name>

    Print a VM's IP, resolved from the host's DHCP leases (bridge100). Errors
    if the VM has no lease yet.
    """,
    "displays" => """
    Usage: vzbeam displays

    Show the host display(s) and suggested --resolution values for `vzbeam run`.
    """
  }

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
  def run(["help", verb]), do: verb_help(verb)
  def run([verb, "--help"]) when is_map_key(@help, verb), do: {:ok, @help[verb]}
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

  defp verb_help(verb) do
    case @help do
      %{^verb => text} -> {:ok, text}
      _ -> {:error, 2, ["no help for: ", verb, "\n", @usage]}
    end
  end
end
