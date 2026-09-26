# OpenBSD guests

vzbeam can install OpenBSD 7.9 or newer for ARM64 from a local ISO. Installation is
interactive: vzbeam opens the Virtualization.framework window and waits until the
guest powers off.

## Requirements

- A physical Apple Silicon Mac running a supported macOS release.
- An OpenBSD ARM64 installation ISO such as `install79.iso`.
- The `vz` sidecar built and signed with `mix vz.build`.

Interactive installation and normal boot retain vzbeam's macOS 13 minimum. Recovery
with `run --iso` requires macOS 15 or newer because vzbeam uses runtime USB hot-plug
to keep the installed disk out of EFI boot selection.

OpenBSD guest boot cannot be validated from a virtualized development Mac. The unit
and native configuration checks verify the command protocol and generic EFI device
graph; an actual install, boot, and recovery session still requires physical Apple
Silicon hardware.

## Verify OpenBSD media

vzbeam accepts local regular files and stores install media by SHA256 digest under
`$VZBEAM_HOME/cache/iso`. That digest prevents duplicate cache entries; it does not
authenticate the release.

Before installing, verify the ISO's SHA256 and OpenBSD release signatures yourself
against the official signed release manifest. vzbeam does not perform this check.

## Install

Start the interactive installer:

```sh
vzbeam new obsd --iso /path/install79.iso
```

The SSH user defaults to `admin`. To store another non-root user in the bundle, pass
`--ssh-user USER` and create that same user in the installer:

```sh
vzbeam new obsd --iso /path/install79.iso --ssh-user operator
```

Inside the installer:

1. Install OpenBSD onto the VirtIO disk.
2. Create the stored SSH user (`admin` in these examples).
3. Leave `sshd` enabled.
4. At the final *Exit to (S)hell, (H)alt or (R)eboot?* prompt, answer `s`, then run
   `halt -p`. The installer's own (H)alt runs plain `halt`, which stops the guest
   without powering it off, so `vzbeam new` keeps waiting.

The command treats guest power-off as installation completion. A reboot keeps the
ISO attached and continues the same interactive session; it does not finish `new`.
If you answered (H)alt (then pressed a key) or (R)eboot, the guest restarts into
either the installed system or the installer, depending on which disk EFI boots.
The install on the disk is complete either way: in the installed system, log in as
root and run `halt -p`; in the installer, choose (S)hell and run `halt -p`.

Closing the installer window only hides it; the installation keeps running. Switch
back to `vz` (Dock or Cmd-Tab) to bring the window back. To cancel, press Ctrl-C in
the terminal running `vzbeam new`, which discards the new bundle.
After power-off, the completed bundle contains `config.json`, `disk.img`, and
`nvram.bin`.

If finalization fails after power-off, vzbeam preserves the completed directory and
prints both its location and the intended final bundle path. Do not rerun `vzbeam new`
for that name: a later creation may treat a dead pending owner as stale. First confirm
that no creation process is active, resolve the reported lock or destination collision,
move the preserved directory to the printed final path if needed, and remove only its
`install-owner.json` marker. The other bundle files are the completed installation.
If vzbeam could not write `config.json` itself, it prints the config after the paths;
save it as `config.json` in the preserved directory before moving it, since that config
holds the install's generated identity and exists nowhere else.

## First normal boot and SSH setup

Boot with a window for the first post-install check:

```sh
vzbeam run obsd --gui
vzbeam ip obsd
ssh-copy-id -i "${VZBEAM_HOME:-$HOME/.local/share/vzbeam}/keys/id_ed25519.pub" admin@<ip>
```

If `VZBEAM_HOME` is unset, its default is `~/.local/share/vzbeam`.

For graceful `vzbeam stop`, add this exact narrow rule to `/etc/doas.conf` in the
guest:

```text
permit nopass admin as root cmd /sbin/shutdown args -p now
```

Replace `admin` only if the bundle was created with a different `--ssh-user`.
`vzbeam stop` runs `doas -n /sbin/shutdown -p now`; `vzbeam kill` remains the
force-power-off fallback.

## Normal GUI and headless boot

Normal runs do not attach installation media:

```sh
vzbeam run obsd --gui
vzbeam run obsd --headless
vzbeam ssh obsd
vzbeam stop obsd
```

Headless mode is the default, so `vzbeam run obsd` is equivalent to the second form.

## Cached recovery

Attach the ISO retained during installation for one recovery invocation:

```sh
vzbeam run obsd --iso
```

`--iso` implies `--gui` and cannot be combined with `--headless`. The cached medium
is attached read-only, remains attached if the guest reboots during this invocation,
and is detached on the next normal run. vzbeam boots with only the recovery medium,
then hot-plugs the installed disk before reporting that the VM started.

## One-shot recovery

Attach another local ISO without caching it or changing the bundle:

```sh
vzbeam run obsd --iso /path/alternate.iso
```

This medium is also read-only and lasts only for that `vzbeam run`. It does not replace
the bundle's cached install-media reference or add the alternate ISO to the cache.

## Recovery shell and the installed disk

At the installer prompt, enter `S` to open a shell. Recovery media is normally `sd0`
and the installed disk is `sd1`; confirm the detected disks before running repair
commands:

```sh
sysctl hw.disknames
```

The installer's minimal `/dev` does not initially include device nodes for `sd1`.
Create them before inspecting, mounting, or repairing the installed disk:

```sh
cd /dev
sh MAKEDEV sd1
disklabel sd1
```

`MAKEDEV` changes only the installer's temporary `/dev`; it does not modify the disk.
The temporary device nodes disappear when the installer reboots, so repeat the
`cd /dev` and `sh MAKEDEV sd1` commands after each reboot. Use the partition names
reported by `disklabel` for any subsequent filesystem checks rather than assuming a
particular layout.

## Disk growth

Host-side growth is available for a stopped OpenBSD guest:

```sh
vzbeam set obsd --disk-gb 96
```

This enlarges the sparse host disk image only. The new capacity appears as
unallocated guest space. Inspect the actual OpenBSD partition layout, then use the
appropriate OpenBSD disk and filesystem tools inside the guest to partition and grow
into it. Do not assume host-side resizing has changed an OpenBSD partition or
filesystem.

Cloning preserves the guest type, stored SSH user, cached-media reference, disk, and
EFI variables, while assigning a new generic machine identifier and MAC address:

```sh
vzbeam new obsd-copy obsd
```

## Unsupported sharing and the hardware-validation boundary

vzbeam's VirtioFS `run --share` path is not supported for OpenBSD and is rejected
before launch. Use network transfer or another guest-supported method instead.

`mix test` and `vzcheck` cover manifest policy, argument construction, generic EFI
platform configuration, VirtIO block/network devices, read-only recovery-media
attachment, delayed USB disk hot-plug configuration, graphics/input configuration,
and EFI variable-store handling without booting a VM.
They do not prove that a particular OpenBSD ISO installs, boots, or selects recovery
media. Those checks belong to the physical Apple Silicon acceptance gate.

## Upgrading from an older vzbeam

An ownerless `<name>.pending` directory created by an older vzbeam release is not
deleted automatically. The CLI prints its exact path. After verifying that no
`vzbeam new` process is active for that bundle, remove only that incomplete directory
and retry the command.
