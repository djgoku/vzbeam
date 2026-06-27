# vzbeam

Clean, disposable **macOS** VMs on Apple Silicon for testing, CI, and sandboxing. Restore an
image, clone it instantly (copy-on-write), run it GUI or headless, SSH in, then tear it down —
all on Apple's **Virtualization.framework**, with no third-party runtime and no paid Apple
Developer account.

vzbeam is split into two pieces:

- a **minimal Swift sidecar** (`vz`) — the only component that links Virtualization.framework;
- an **Elixir CLI engine** — all orchestration: filesystem, config, lifecycle, SSH, lease parsing.

## Status

**Plans 1–4 implemented** — the full CLI plus the Swift `vz` sidecar:

- `ls` / `ip` / `images` — inspect bundles, IPs, cached restore images
- `fetch <spec>` — download + cache a restore image
- `new <name> --image <spec>` (restore) · `new <name> <base>` (CoW clone) · `rm`
- `run <name> [--gui|--headless] [--share tag=/path]` · `stop` · `kill` · `ssh <name> [-- cmd]`
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

The engine has **159 green tests**. On bare-metal Apple Silicon (a release macOS), the boot-dependent
paths are hardware-validated: restore, boot + `--gui`, CoW clone, headless networking + `ssh`, virtiofs
`--share`, `kill`, and the 2-VM cap (both the engine pre-check and the framework's authoritative
`VZError 6`) — and the packaged single-file binary boots a guest from its **bundled** sidecar. See the
hardware-suite results in `docs/superpowers/results/`.

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

Requires the Swift toolchain plus Zig 0.15.2, `xz`, and `7z` — provisioned by `mise install` from
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

> **macOS 26 (Tahoe) build host:** Zig 0.15.2 resolves libSystem via `xcrun`, which on Tahoe returns
> the macOS 26 SDK — whose `.tbd` dropped the `arm64-macos` entries Zig needs, so `mix release` fails
> with `undefined symbol: _malloc_size` (and friends). `SDKROOT` does **not** help — Zig ignores it
> here. Until Burrito ships a Tahoe-compatible Zig, either build on macOS ≤ 15, or shadow `xcrun`
> earlier on `PATH` with a wrapper that points `--show-sdk-path` at
> `/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk` (the macOS 15 SDK, installed alongside 26).

## Install a prebuilt `vzbeam` via mise/aqua

Rather than build, install a released binary straight from GitHub Releases with mise — point
it at this repo's single-file aqua registry (`aqua/registry.yaml`):

```sh
MISE_AQUA_REGISTRIES=https://raw.githubusercontent.com/djgoku/vzbeam/main/aqua/registry.yaml \
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

## A note on validation

`mix test` validates the **entire Elixir engine** and is the validation entry point for everything
implemented so far. It does **not** — and cannot — validate the VM-booting paths (`install` / `run`):
Apple's Virtualization.framework does not support running a macOS guest inside a macOS guest, so a
*virtualized* dev box can't boot guests at all. Those paths are validated on **bare-metal Apple
Silicon** via a separate, hardware-gated suite — see the design spec §13 / §15. A green `mix test`
means the engine is sound, not that the VM lifecycle has been exercised.

## Docs

- Design spec: `docs/superpowers/specs/2026-06-21-vzbeam-design.md`
- Implementation plans: `docs/superpowers/plans/`
