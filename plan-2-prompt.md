# vzbeam — Plan 2 (image + clone) handoff (paste into a fresh session)

You are continuing **vzbeam**, a tool that spins up throwaway **macOS** VMs on Apple Silicon built
directly on Apple's **Virtualization.framework** (no third-party runtime, no paid Apple Developer
account). It is split into a **minimal Swift `vz` sidecar** (the only code that links VZ) and an
**Elixir CLI engine**. This is the **same repo** — Plan 1 is already merged to `main`, so **read the
spec, plan, and code rather than taking anything below on faith** (validate, don't assume).

Three memory files auto-load for this project: `vzbeam-validation-environment`,
`vzbeam-collaboration-style`, `vzbeam-plan-progress`. Read them.

## Your mission

**Brainstorm, then (after we agree on a spec + plan) implement Plan 2 — image + clone:** the verbs
`fetch`, `images`, `new`, and `rm`. Do **not** write product code during brainstorming. Start with the
`brainstorming` skill, confirm a spec and plan with me, then execute.

## What's already on `main` (Plan 1 — don't re-create it)

The Elixir engine foundation, fully tested (`mix test` → 26 green; `mix escript.build` → `./vzbeam`).
Build on these **realized** module interfaces (verify in `lib/vzbeam/`):

- `VzBeam.Home` — `root/0`, `bundle_dir/1`, `bundles/0` (`$VZBEAM_HOME`, default `~/.local/share/vzbeam`)
- `VzBeam.Defaults` — `values/0`, `resolve/2` (flag > default), `describe/0` (built-in `cpu/mem_gb/disk_gb/resolution/ssh_user`; **no config file**)
- `VzBeam.Manifest` — `read/1 :: {:ok, map}|{:error, term}`, `write/2 :: :ok|{:error, term}` (atomic temp-then-rename, stamps `"schemaVersion": 1`, preserves unknown keys; string-keyed JSON)
- `VzBeam.Pidfile` — `read/1`, `write/2`, `running?/1 :: boolean` (`vm.pid` JSON `{pid, startedAt, bundle}`; liveness = pid alive AND `ps` start-time match)
- `VzBeam.Leases` — `parse/1`, `lookup_ip/2` (pure dhcpd_leases parser)
- `VzBeam.CLI` — `run/1` dispatch (`{:ok, iodata} | {:error, code, iodata}`) + thin `main/1`. **Plan 2 adds `fetch`/`images`/`new`/`rm` clauses + `@usage`.**
- `VzBeam.Commands.{Ip, Ls}` — the verb pattern to follow: `run/1` delegates to `run/2` with an **injectable** side-effect fn (for testability); returns `{:ok, iodata} | {:error, code, iodata}`.

Bundle/manifest model (spec §5): a bundle dir under `$VZBEAM_HOME/<name>/` holds `config.json`
(manifest: `name`, `base` lineage, `image: {version, build, source}`, opaque `machineIdentifier` /
`hardwareModel` / `macAddress`, `cpuCount`, `memoryBytes`, `createdAt`), `disk.img`, `aux.img`,
`vm.pid`, `run.log`. IPSW cache: `$VZBEAM_HOME/cache/ipsw/` + an `index.json`.

## What Plan 2 builds (spec §7)

- `fetch <latest|PATH>` — download + cache an IPSW; record version/build in `cache/ipsw/index.json`.
- `images` — list cached IPSWs with version/build.
- `new <name> <base>` — clone a **cleanly-stopped** base via APFS `cp -Rc` (CoW), then `reid` (fresh MAC + machine identity). `<base>` is **required** (no default). Inherits the base's `image` block, sets `base: <base>`.
- `new <name> --image <latest|PATH>` — **restore** a cached image into a fresh base; auto-`fetch` if uncached. Mutually exclusive with a positional base.
- `rm <name>` — delete the bundle (refuse a running VM without `--force`, then stop first). **No base special-casing** — CoW clones are independent.

## The load-bearing strategy: build against a FAKE sidecar

`fetch`/`new` need the Swift `vz` sidecar (`image-info`, `restore`, `reid`) — but **the Swift sidecar
doesn't exist yet (it's Plan 4).** So Plan 2 builds the Elixir orchestration against the **JSON-lines
wire protocol** (spec §4) and tests it with a **fake `vz`** (a shell script emitting canned JSON).
Only the sidecar calls are faked; the **`cp -Rc` clone is real and testable here.**

Protocol events the Plan-2 verbs consume (spec §4) — short-lived calls via `System.cmd`:
- `image-info` → `{"type":"image","version":"26.5.1","build":"25F80","url":"…","source":"latest"}`
- `restore` → `{"type":"progress","fraction":…}` … `{"type":"restored","machineIdentifier":"<b64>","hardwareModel":"<b64>","macAddress":"…","version":"…","build":"…"}`
- `reid` → `{"type":"reid","machineIdentifier":"<b64>","macAddress":"…"}`
- errors → `{"type":"error","domain":"VZErrorDomain","code":N,"message":"…"}`

**Open design question for brainstorming:** Plan 2 likely needs a new `VzBeam.Sidecar` module
(locate `vz` via env `VZBEAM_VZ` → alongside the CLI → `$PATH`; `vz --version` protocol check; invoke
via `System.cmd`) and a `VzBeam.Protocol` JSON-lines decoder (newline-buffered; oversize reject;
EOF-before-terminal = error; `{"type":"error"}`/non-zero exit dominates). Decide their shape and how
tests inject the fake `vz`.

## Validated facts / gotchas Plan 2 must respect

- **Clone only a cleanly-stopped base** — `new` must refuse to clone a base whose `Pidfile.running?/1` is true (unflushed writes corrupt CoW clones).
- **Regenerate BOTH MAC and machine identity per clone** (`reid`) — same-MAC clones collide on DHCP.
- **`cp -Rc` is APFS copy-on-write** and clones survive base deletion intact (spike-verified in the prior session).
- **Atomic clone:** clone into a `.pending` temp dir → `reid` → write manifest → rename to final `<name>`, so a crash never leaves a half-cloned bundle carrying the base's identity.
- **`rm`** just deletes; `--force` to stop+delete a running VM; no base warning.
- **`VZMacOSRestoreImage`** exposes `operatingSystemVersion` + `buildVersion` + `url` (validated) — that's where the `image` block comes from.
- **`fetch latest` caveat:** resolving "latest" uses `VZMacOSRestoreImage.fetchLatestSupported`, whose Apple catalog was **unreachable in this dev sandbox** last session ("catalog failed to load"). Plan for testing `fetch` with a local IPSW path and a fake `image-info`; don't assume `latest` works here.

## Do these cleanups first (queued from Plan 1's code review — they touch the modules Plan 2 edits)

- Extract a shared **`VzBeam.AtomicFile`** (atomic write is duplicated in `Manifest` + `Pidfile`; also give `Pidfile.write/2` the `mkdir_p` that `Manifest` has).
- Dedup the lease reader (`read_leases/0` is copy-pasted in `commands/ip.ex` + `commands/ls.ex`).
- Broaden `Ls.mem/1` (and `cpuCount` rendering) to `is_number` for float-encoded JSON.
- Normalize `Pidfile.write/2`'s error return (it mixes `{:error, :process_not_found}` with raw `{:error, posix}`).
- Reconcile `vm.pid`'s `pid` type: code stores a **string**, spec §5 shows an **integer** — pick one and make spec + code agree (note: the run lifecycle in Plan 3 is the first real writer).

## Validation environment reality (critical)

This build host is a **virtualized** macOS box (`kern.hv_support=0`) and **cannot boot VZ guests** —
macOS-in-macOS is unsupported on Apple Silicon. So:
- **Green bucket (test here):** all of Plan 2's Elixir orchestration, the `cp -Rc` clone, the fake-sidecar protocol, the cache/index logic.
- **Needs bare-metal Apple Silicon:** the *real* `restore`/`run` (Plan 3/4). A green `mix test` does not exercise booting.
- Toolchain: Elixir 1.20.1 + Erlang/OTP 29 via `mise` (global), hex 2.4.2, `mix` on `$PATH`. Network works from the sandbox (hex reachable; Apple's IPSW/catalog endpoints untested).

## How to work (project conventions)

- **Brainstorm → spec (`docs/superpowers/specs/`) → `writing-plans` → subagent-driven execution → task + whole-branch reviews → `finishing-a-development-branch`.** Confirm the spec and plan with me before building.
- **Validate, don't assume.** Prove framework/tooling behavior with a minimal, non-mutating spike before relying on it. State plainly what's validated vs. open.
- **Use Codex review points where they make the most sense** (e.g. a spec critique before the plan, the riskiest mechanism before it becomes code).
- **Don't over-engineer** (YAGNI hard — minimal verb surface; ask before adding extras).
- Branch off `main`; per-task TDD commits; merge only when I approve.

## References

- Design spec: `docs/superpowers/specs/2026-06-21-vzbeam-design.md` — esp. **§4** (wire protocol), **§5** (data model), **§7** (verbs), **§8** (lifecycle, for Plan 3 context), **§12** (validated facts), **§13** (validation env), **§16** (deferred non-goals).
- Plan 1 (for the task/TDD style to mirror): `docs/superpowers/plans/2026-06-21-vzbeam-engine-foundation.md`.
- Code: `lib/vzbeam/` on `main`. README: `README.md`.

## Start by

Invoking the `brainstorming` skill and working the open questions with me — chiefly the **`Sidecar` /
`Protocol` module shape + fake-`vz` test strategy**, and the **`fetch`/cache design** (what
`index.json` holds, how `new --image` auto-fetches). Then propose a spec, then a plan. Keep it minimal;
**confirm with me before writing product code.**
