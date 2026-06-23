# vzbeam

Throwaway **macOS** virtual machines on Apple Silicon, built directly on Apple's
**Virtualization.framework** — no third-party VM runtime (Tart/Lima/UTM) and no paid Apple Developer
account (ad-hoc codesign + a single entitlement).

A clean-room rewrite of `sbx`, split into two pieces:

- a **minimal Swift sidecar** (`vz`) — the only component that links Virtualization.framework;
- an **Elixir CLI engine** — all orchestration: filesystem, config, lifecycle, SSH, lease parsing.

## Status

**Plan 1 (Elixir engine foundation) — done.** Working today:

- `vzbeam ls` — list VM bundles (status / base / OS / IP / cpu / mem)
- `vzbeam ip <name>` — a bundle's IP, read from the DHCP leases

plus the storage, manifest, pidfile, and lease-parsing layer underneath. Upcoming (see
`docs/superpowers/plans/`): image fetch + CoW clone (`fetch` / `new` / `rm`), the run lifecycle
(`run` / `stop` / `kill`), and the Swift `vz` sidecar.

## Build, test, run

Requires Elixir `~> 1.17` and a compatible Erlang/OTP (e.g. `mise use erlang elixir`, asdf, or
`brew install elixir`).

```sh
mix deps.get
mix test                 # the validation suite
mix escript.build        # builds ./vzbeam
./vzbeam ls
./vzbeam ip <name>
```

Storage lives under `$VZBEAM_HOME` (default `~/.local/share/vzbeam`) — relocate it (e.g. to an
external SSD) with that one env var.

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
