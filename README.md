# vzbeam

Clean, disposable **macOS** VMs on Apple Silicon for testing, CI, and sandboxing. Restore an
image, clone it instantly (copy-on-write), run it GUI or headless, SSH in, then tear it down —
all on Apple's **Virtualization.framework**, with no third-party runtime and no paid Apple
Developer account.

vzbeam is split into two pieces:

- a **minimal Swift sidecar** (`vz`) — the only component that links Virtualization.framework;
- an **Elixir CLI engine** — all orchestration: filesystem, config, lifecycle, SSH, lease parsing.

## Commands

The full CLI, backed by the Swift `vz` sidecar:

- `ls` / `ip` / `images` — inspect bundles, IPs, restore images (cached `local` + Apple-offered
  `remote`, straight from Apple's IPSW catalog — no third-party services)
- `fetch <spec>` — download + cache a restore image
- `new <name> --image <spec>` (restore) · `new <name> <base>` (CoW clone) · `rm` — `new` accepts
  `--cpu N`, `--mem-gb M`, `--disk-gb G` (a clone's disk can only grow past its base)
- `set <name> [--cpu N] [--mem-gb M] [--disk-gb G]` — resize a stopped VM (the disk only grows)

Disk-sizing caveat: growing an *existing* VM (`set --disk-gb`, or a clone's `--disk-gb`) cannot
extend the guest's root volume — macOS keeps the SIP-protected recoveryOS partition right behind
it, so the added space is only usable as a new APFS volume inside the guest. For a full-size root
volume, pass `--disk-gb` on a fresh `new --image` restore, where the installer partitions the
whole disk — or, for disposable VMs, see the experimental host-side procedure in
[docs/disk-grow.md](docs/disk-grow.md) (deletes the guest's recoveryOS to let the root grow).
- `run <name> [--gui|--headless] [--share <tag>=/host/path]` · `stop` · `kill` · `ssh <name> [-- cmd]`
  — see [Sharing a host folder](#sharing-a-host-folder)
- `mix vz.build` — compile + ad-hoc-sign the Swift sidecar into `$VZBEAM_HOME/bin/vz`
- `MIX_ENV=prod mix release` — package the CLI + the signed sidecar into one self-contained binary (Burrito; no Erlang/Elixir/Swift on the target — see *Packaging* below)

An image `<spec>` (for `fetch` and `new --image`) is one of:

- `latest` — Apple's latest supported restore image
- a **local path** to an `.ipsw`
- an **`https://` URL** to an `.ipsw` — downloaded (with a progress bar) and cached; re-fetching the
  same URL is a no-op
- a cached **build id** from `vzbeam images` (e.g. `26A5368g`, case-insensitive) — reused straight
  from the cache, no download

All four resolve to a cached image keyed by its build, so the disk is never duplicated.

## Build, test, run

Requires Elixir `~> 1.17` and a compatible Erlang/OTP (e.g. `mise use erlang elixir`, asdf, or
`brew install elixir`).

```sh
mix deps.get
mix test                 # the validation suite
mix escript.build        # builds ./vzbeam
mix vz.build             # builds + ad-hoc-signs the Swift sidecar -> $VZBEAM_HOME/bin/vz
./vzbeam ls
./vzbeam ip <name>
```

`mix vz.build` requires the Swift toolchain (Command Line Tools) and runs per machine; it re-signs the
sidecar with the `com.apple.security.virtualization` entitlement on every build. Storage lives under
`$VZBEAM_HOME` (default `~/.local/share/vzbeam`) — relocate it (e.g. to an external SSD) with that one
env var.

## Packaging a single-file binary (Burrito)

Produce one self-contained `vzbeam` for Apple-Silicon macOS (≥ 13) — no Elixir/Erlang/Swift
needed on the target. The ad-hoc-signed `vz` sidecar rides inside the binary's payload.

Requires the Swift toolchain plus Zig 0.16.0, `xz`, and `7z` — provisioned by `mise install` from
`mise.toml`, with the exact resolved versions captured in `mise.lock` — on the **build** Mac:

```sh
MIX_ENV=prod mix release         # -> ./burrito_out/vzbeam_macos_silicon  (carries the signed vz)
scp ./burrito_out/vzbeam_macos_silicon user@mac:/usr/local/bin/vzbeam
```

`scp`/`rsync`/`tar`/`git` **normally** add no `com.apple.quarantine` xattr, so the ad-hoc-signed
binary runs as-is. Verify on the target before first run:

```sh
xattr ./vzbeam | grep -q com.apple.quarantine && echo "quarantined — clear it (below)" || echo "not quarantined"
```

If it IS quarantined (browser/AirDrop download), clear it once — on macOS 26 a quarantined binary
**hangs** at launch (Gatekeeper blocks it before the payload unpacks) rather than printing an error:

```sh
xattr -dr com.apple.quarantine ./vzbeam
```

`VZBEAM_DEBUG=1 vzbeam <cmd>` prints which `vz` sidecar was selected. The bundled sidecar is
overridable by `$VZBEAM_VZ` or a `mix vz.build` install in `$VZBEAM_HOME/bin/vz`.

## Install a prebuilt `vzbeam` via mise/aqua

Rather than build, install a released binary straight from GitHub Releases with mise — point
it at this repo's single-file aqua registry (`registry.yaml` at the repo root, so the plain
repo URL works):

```sh
MISE_AQUA_REGISTRIES=https://github.com/djgoku/vzbeam \
  mise install aqua:djgoku/vzbeam@latest        # or @0.1.0 for a specific release
```

mise verifies the download against the GitHub asset digest and installs it under its data dir
(`mise which aqua:djgoku/vzbeam` prints the path; `mise use aqua:djgoku/vzbeam@latest` adds it
to a project). The install is quarantine-free, so the ad-hoc-signed binary runs as-is.
Apple-Silicon macOS only, and it needs a published release to install from.

## First boot (one-time per base)

A freshly restored base is unconfigured, so the **first** `run` must be `--gui` to complete macOS
Setup Assistant:

```sh
vzbeam run base --gui     # a window opens (it has a Dock icon). In the guest:
                          #   - create the user `admin`
                          #   - System Settings ▸ General ▸ Sharing ▸ enable Remote Login
```

Then install the baked SSH key, and — so `vzbeam stop` can shut the guest down gracefully — grant
`admin` passwordless `shutdown`:

```sh
vzbeam ip base                                                  # note the IP
ssh-copy-id -i "$VZBEAM_HOME/keys/id_ed25519.pub" admin@<ip>    # one-time key install
# in the guest (stop runs `sudo -n shutdown -h now` over SSH):
echo 'admin ALL=(ALL) NOPASSWD: /sbin/shutdown' | sudo tee /etc/sudoers.d/vzbeam-shutdown
```

This persists on the base and is inherited by every CoW clone — paid once. (`vzbeam kill` force-stops a
guest and needs none of this.)

## Sharing a host folder

`run --share <tag>=/host/path` exposes one host directory to the guest over VirtioFS. **`<tag>` is a
name you choose, not a keyword** — it is the handle the guest mounts by, and the host path is never
visible inside the guest. Pick something short (≤ 36 bytes, no `=`); the guest mounts it by tag:

```sh
# host
vzbeam run dev --share apps=/Volumes/Extreme-SSD/vzbeam/apps

# guest
mkdir -p apps
mount_virtiofs apps apps          # mount_virtiofs <tag> <mount-point>
```

Mounting by host path (`mount_virtiofs /Volumes/Extreme-SSD/vzbeam/apps apps`) fails with
`fs_tag ... not found` — the guest only ever knows the tag.

Three limits worth knowing:

- **Per-run, not persisted.** The share is not recorded in the bundle, so `--share` must be passed on
  every `run`; a VM booted without it has no share at all.
- **The guest mount is not persistent.** `mount_virtiofs` does not survive a guest reboot — re-run it
  (or wire it into a guest launchd job) each time.
- **VirtioFS has no `fsync` barrier, and the BEAM has no fallback.** Plain `fsync(2)` works on the
  share, but `fcntl(F_BARRIERFSYNC)` — which is how Darwin implements Erlang's `file:sync/1` —
  returns `ENOTTY`, and OTP surfaces that errno verbatim instead of retrying with `fsync(2)` the way
  SQLite does. Measured on an `AppleVirtIOFS` mount: Python's `os.fsync()` → ok, Erlang's
  `file:sync/1` → `{error,enotty}`. It bites `mix deps.get` whenever `HEX_HOME` points inside the
  shared tree: resolution and the downloads finish, then Hex's registry-cache write
  (`:ets.tab2file(…, sync: true)`) dies with `{:file_error, '…/.mise-hex/cache.ets', :enotty}`. Keep
  Hex/Mix homes and build output on the guest's own disk; use the share for source and transfer.

## A note on validation

`mix test` is the validation entry point for everything implemented so far. It does **not** — and cannot — validate the VM-booting paths (`install` / `run`):
Apple's Virtualization.framework does not support running a macOS guest inside a macOS guest, so a
*virtualized* dev box can't boot guests at all. Those paths are validated on **bare-metal Apple
Silicon** via a separate, hardware-gated suite: restore, boot + `--gui`, CoW clone, headless
networking + `ssh`, virtiofs `--share`, `kill`, the 2-VM cap (the engine pre-check and the framework's
authoritative `VZError 6`), and the packaged single-file binary booting a guest from its **bundled**
sidecar. See the design spec §13 / §15 and the hardware-suite results in `docs/superpowers/results/`.
A green `mix test` means the engine is sound, not that the VM lifecycle has been exercised.

## Docs

- Design spec: `docs/superpowers/specs/2026-06-21-vzbeam-design.md`
- Implementation plans: `docs/superpowers/plans/`
