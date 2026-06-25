# vzbeam — from-scratch rewrite brainstorm prompt (paste into a fresh, zero-context session)

> Self-contained. You have **no prior context** on `sbx` or `vzbeam`; everything load-bearing is
> inline. The existing implementation lives at `~/src/sbx` — treat it as a **reference and a source
> of validated facts**, not as code to port line-by-line. Verify any claim below against that repo
> before relying on it (validate-don't-assume).

## Your mission

Design (then, after we agree, build) **`vzbeam`**: a clean-room rewrite of an existing tool called
`sbx`. `sbx` spins up throwaway **macOS** virtual machines on Apple Silicon,
built **directly on Apple's `Virtualization.framework`** — no third-party VM runtime (no Tart/Lima/
UTM), and **no paid Apple Developer account** (ad-hoc codesigning with one entitlement is enough).

The rewrite has these fixed constraints (already decided — not up for debate):

1. **Minimal Swift.** Keep Swift to *only* the code that must link `Virtualization.framework`.
   Everything that doesn't touch a `VZ…` type moves out of Swift.
2. **Elixir for the CLI/orchestration.** **Burrito** (single self-contained binary) is the
   *eventual* packaging step, **deferred until we're ready to ship.** Build the tooling so adopting
   Burrito is **config-only — no rewrite.** See "Packaging" below.
3. **macOS guests only, one-shot CLI** — no daemon, no Linux. These were reasoned through and
   settled (see "Scope decisions"); don't reopen them without a new reason.
4. **Brainstorm first.** Do **not** write code yet. Start with the `brainstorming` skill, then a
   spec, then a plan. Confirm with me before building.

The Swift↔Elixir interop question — briefly, whether to use
[`otp-interop/swift-erlang-actor-system`](https://github.com/otp-interop/swift-erlang-actor-system)
(Swift distributed actors over Erlang's `erl_interface` C-node API) — is **already settled → no**: a
one-shot CLI has no persistent BEAM node for a Swift node to attach to, so interop is just "Elixir
spawns the signed Swift binary as a subprocess and parses stdout." Full reasoning under "Scope
decisions."

---

## What `sbx` is (domain context)

A personal tool to spin up isolated, **throwaway** VMs on one Apple Silicon Mac. Two use cases drive
every design choice:

1. **Throwaway macOS desktop (GUI):** boot a VM in a window, do risky/manual work, then delete it.
2. **Agent / dev sandbox (CLI-first):** clone a base → an agent (e.g. Claude) works in it over SSH →
   artifacts land in a shared folder → extract them to the host → destroy the clone.

Guiding metric: *fastest path to a repeatable **spin-up → work → extract → destroy** loop, with no
third-party VM runtime.* Host this was built on: M1 Max, 64 GB RAM, 10 cores, macOS 26.x, arm64.

### Current architecture (the part that matters)

A **hard boundary** — and it's the whole point of the design:

- **`sbx-vz`** — a small **Swift** binary (~570 LOC across 8 files). The *only* component that links
  `Virtualization.framework`, and therefore the only one that needs the
  `com.apple.security.virtualization` entitlement + codesign. Subcommands today: `install`, `run`
  (GUI or headless), `ip`, `reid`, `selftest`. Operates on a single **bundle directory**; stateless
  beyond that bundle.
- **`bin/sbx`** — a ~287-line **zsh wrapper**. Pure orchestration: filesystem, process, ssh, lease
  parsing, the clone/rm/ls/config lifecycle. Touches no `VZ…` type. **This is essentially what
  becomes the Elixir app.**

A VM **bundle** is a directory cloned as a unit:

```
<name>/
  config.json   # base64 machineIdentifier + hardwareModel, cpuCount, memoryBytes, macAddress
  disk.img      # main disk, sparse
  aux.img       # VZMacAuxiliaryStorage (NVRAM)
  vm.pid        # written while running; removed on clean stop
```

Storage root is `$SBX_HOME` (default `~/.local/share/sbx`), intentionally the **only** storage
switch (relocatable to an external SSD with no code change). SSH keypair at `$SBX_HOME/keys/
id_ed25519`. Guest user `admin`, Remote Login enabled. Clean boot ≈ 3–8 s to SSH.

---

## Features to KEEP (the validated, working surface)

Carry all of this forward. Every item is implemented and verified in `sbx` today.

| Capability | Notes for the rewrite |
|---|---|
| **Direct on `Virtualization.framework`** | No third-party runtime. Ad-hoc codesign + one entitlement; no paid account. This is the core identity of the project — do not regress it. |
| **Bundle model** | `config.json` + `disk.img` (sparse) + `aux.img` + `vm.pid`. Reading/writing `config.json` is pure JSON — belongs in **Elixir**; Swift only needs the platform fields at install/run time. |
| **`install` from IPSW** | `--ipsw latest` auto-fetches Apple's current restore image and **caches** it under `$SBX_HOME/cache/ipsw` (VZMacOSInstaller needs a local file URL), or pass a local IPSW path. Sizing: `--disk-gb`, `--cpu`, `--mem-gb`. **Swift-only** (VZMacOSRestoreImage/VZMacOSInstaller/VZMacAuxiliaryStorage). |
| **`run` GUI** | AppKit `VZVirtualMachineView` window (default 1280×800). **Swift-only** (AppKit + VZ). |
| **`run` headless** | No window, but a graphics device is still attached. **Swift-only.** |
| **Configurable display resolution** | `--resolution WIDTHxHEIGHT` for the guest display (default 1920×1200), independent of the host window. |
| **NAT networking** | `VZNATNetworkDeviceConfiguration`; guest gets internet, host reaches guest by IP. |
| **Key-based SSH** | Baked key in `$SBX_HOME/keys`; non-interactive after one-time `ssh-copy-id`. Pure orchestration → **Elixir**. |
| **virtiofs file share** | `--share tag=/host/path`, read-write, round-trips both directions (guest `mount_virtiofs`). Swift attaches the device; the mount/extract workflow is **Elixir**. |
| **IP discovery** | Parse `/var/db/dhcpd_leases` by the bundle's MAC. **Pure parsing → Elixir** (no VZ needed). |
| **Lifecycle: stop / kill** | pidfile + signal trap → graceful `requestStop()` → force-stop fallback; `guestDidStop → exit(0)` so the host process frees the guest's RAM. `stop` = guest-side `shutdown -h now`; `kill` = force power-off. The *decisions* are orchestration (**Elixir**); the *VZ calls* are Swift. |
| **`new` — CoW clone** | APFS `cp -Rc` (instant copy-on-write) of a **cleanly-stopped** base, then **`reid`** mints a fresh MAC + `VZMacMachineIdentifier`, so clones get distinct NAT IPs and run concurrently. `cp -c` is **Elixir**; minting VZ identities is **Swift** (`reid`). |
| **`rm`** | Stop if running, then `rm -rf` the bundle; refuses to delete `base`. **Elixir.** |
| **`ls`** | Bundles with status / IP / cpu / mem / disk / path. **Elixir.** |
| **`config`** | `cpu`/`mem_gb`/`disk_gb` install defaults in a TOML file; `path|show|get|set`. The hand-rolled zsh TOML parser should be **replaced** with a real Elixir config story. |
| **Swappable `$SBX_HOME`** | Single env var; relocate to external SSD with no code change. Keep. |

---

## Validated facts / gotchas that MUST survive (do NOT rediscover — each cost real time)

These are proven framework behaviors. The rewrite must respect them regardless of language.

1. **≤ 2 macOS VMs run simultaneously.** Apple's framework hard-caps macOS guests at two; a third
   `vm.start` fails with `VZError Code=6` ("maximum supported number of active virtual machines
   reached"), independent of disk/RAM. So concurrency is tiny by design — count running VMs and
   refuse (or wait) on a third; no fleet scheduler needed.
2. **Headless networking needs `RunLoop.main.run()` on the main queue** — `dispatchMain()` leaves
   networking dead (the host `bridge100` NAT bridge never appears). This was *the* load-bearing fix.
   The Swift `run` process stays long-lived per VM (launched as a detached subprocess by the CLI);
   preserve a real main-thread run loop in it.
3. **A graphics device is attached even headless** (so GUI/GPU/Screen-Sharing stay possible).
   Networking itself does not require it, but this is the proven-good config.
4. **macOS ignores `requestStop()` headless** (it's an ACPI power-button the guest never acts on).
   So `stop` issues a guest-side `shutdown -h now`; a `VZVirtualMachineDelegate.guestDidStop` exits
   the host process (~10 s). `kill` force-stops via `VZVirtualMachine.stop()`.
5. **Clone only a cleanly-stopped base.** Unflushed guest writes corrupt CoW clones. `new` must
   refuse to clone a running base.
6. **Regenerate BOTH MAC and `VZMacMachineIdentifier` (ECID) per clone.** Same-MAC clones collide on
   DHCP; regenerating the MAC alone gives distinct IPs, but `new` regenerates the machine id too for
   a unique hardware identity. Minting these requires the framework (Swift).
7. **First boot needs the GUI once** for Setup Assistant (create the `admin` user, enable Remote
   Login). That state persists on disk for all later headless boots and all clones.
8. **`bridge100` is the readiness tell.** `ifconfig bridge100` appearing within seconds = VM
   networking is up, independent of guest boot speed. Don't conclude "broken" from a too-short SSH
   poll.
9. **Never hard-`pkill` a running guest** (especially the base) — dirty FS → slow recovery boots.
   Always go through clean stop.
10. **Ad-hoc codesign suffices**, but `swift build` **drops the entitlement signature on every
    relink**, so the build re-signs every time (`codesign -s - --entitlements … com.apple.security.
    virtualization`). **This constraint does not go away in the rewrite** — see "Packaging".
11. **zsh does not word-split unquoted `$VAR`.** (A wrapper-language footgun in the current code;
    moot once orchestration is Elixir, but it's why several "VM is broken" episodes were actually
    quoting bugs.)

---

## Features to ADD (roadmap)

- **One-shot `sandbox`**: `new → run headless → (work over SSH) → extract → rm` in a single command.
  This is the agent-sandbox use case as one verb — the highest-value addition.
- **A real `extract`** command (today it's a manual virtiofs/scp workflow).
- **Reproducible base provisioning ("base-as-code")**: a provisioning recipe (shell/Ansible) run
  over SSH against a fresh base, then snapshot via clone — *no Tart/Packer* (researched: Packer can
  only build VZ images via the Tart/Anka plugins, which reintroduce a third-party runtime and their
  own image formats — against this project's premise).
- **Structured config** beyond today's three integers (`cpu`/`mem_gb`/`disk_gb`): per-VM overrides,
  named bases, a default resolution/share.

### What the Elixir rewrite actually buys (at one-shot-CLI scale)
Be honest about the value: with no daemon and a 2-VM ceiling, this is **not** about OTP fleet
supervision. The real wins over the zsh wrapper are:
- **Robust arg parsing + error handling** (the current zsh wrapper has real quoting/round-trip bugs)
  and **a proper test suite**.
- **A real config layer** replacing the hand-rolled zsh TOML parser.
- **A single self-contained CLI binary** via Burrito *at packaging time* (the Swift sidecar still
  ships separately signed — see "Packaging").
- **Cleaner lifecycle/orchestration code** and room for nicer UX (`ls` tables, clear status output).
- The **one-shot `sandbox` flow** above, expressed cleanly.

(If a persistent fleet ever becomes a real need, OTP supervision + a live control channel would be the
reason to revisit a daemon — but that's explicitly out of scope now.)

---

## Scope decisions (resolved 2026-06-21)

These were reasoned through and settled. Treat them as constraints; don't reopen without a new reason.

### One-shot CLI — no daemon
vzbeam is a **one-shot CLI**: each command runs, acts on filesystem state, and exits (exactly the
`sbx` model). **No persistent `vzbeamd`.** A daemon's only real payoff is fleet supervision/queueing
— and with **macOS-only + the ≤2-VM cap** there's effectively no fleet to orchestrate. A running VM
is owned by its **detached per-VM Swift sidecar**, discovered by later commands via pidfile + DHCP
leases (proven in `sbx`); the 2-VM cap is enforced by counting running pidfiles. Accepted trade-off:
status is **poll-based** (no push events). A second trade-off — **Burrito cold-start per
invocation** — applies only *once packaged* (Burrito is deferred; see "Packaging"), and is the most
likely reason you'd ever reconsider a daemon.

### Swift↔Elixir interop — spawn a subprocess (therefore NO `swift-erlang-actor-system`)
Follows directly from one-shot CLI: no persistent BEAM node means a C-node / distributed-actor bridge
has nothing to attach to. Interop is simply **Elixir runs the signed Swift binary as a subprocess
(`System.cmd` for `install`/`reid`/`ip`; a `Port` for the long-lived `run`) and parses its stdout**
(`START_OK`, IP, install %, `GUEST_STOPPED`). Dependency-free; drops the pre-release `erl_interface`
library entirely. (Considered-and-rejected reasoning recorded below.)

### macOS guests only — no Linux
Out of scope. macOS is the whole point, and the only capability not already served by Apple's own
`container` tool (which runs Linux on Virtualization.framework, ad-hoc-signed). Do **not** propose a
`VZLinuxBootLoader` path; if a Linux sandbox is ever needed, delegate to `apple/container`.

### NAT networking only — no bridged
Bridged is **all-Swift to implement** (swap `VZNATNetworkDeviceAttachment` →
`VZBridgedNetworkDeviceAttachment(interface:)`, enumerate NICs via
`VZBridgedNetworkInterface.networkInterfaces`; Elixir just passes a flag). **But** it requires the
**`com.apple.vm.networking`** entitlement — a **restricted/managed** entitlement needing a **paid
Apple Developer account + provisioning profile + Apple approval** (validated,
`~/.claude/knowledge-base/virtualization-framework.md`) — which breaks the "no paid account" premise.
So it's a *premise* decision, not a code one, and it's **out**. NAT already makes the guest
host-reachable (`bridge100` / `192.168.64.0/24`); true bridged would only add *other-LAN-machine*
reachability, which we don't need.

---

## The rewrite's target shape (a starting point to poke holes in, not a final design)

### What stays Swift (the irreducible VZ core)
Only operations that touch a `VZ…` type. Candidate minimal surface:
- **`install`** — fetch/cache IPSW, `VZMacOSInstaller`, create aux storage + sparse disk, write the
  platform fields into `config.json`.
- **`run`** — build `VZVirtualMachineConfiguration` (boot loader, disk, NAT NIC, optional virtiofs,
  graphics + keyboard + pointing device), start the VM, host the GUI window or headless run loop,
  own the stop/kill VZ calls + the `guestDidStop` delegate.
- **`reid`** — mint a fresh `VZMACAddress.randomLocallyAdministered()` + `VZMacMachineIdentifier()`.

Everything else — lease parsing / `ip`, `cp -c` clone, `rm`, `ls`, `config`, `ssh`, the
stop/kill/clone *decisions*, `$SBX_HOME` management — is **Elixir**. (Note `ip` and the entire
`Leases`/`config.json` read path are pure parsing today and have no reason to be Swift.)

### Packaging: defer Burrito, but build Burrito-agnostic
**Don't build around Burrito.** Develop and run the CLI as a plain `mix` project (run via an
**escript** / `mix run` / IEx during the build), and add **Burrito only at the packaging milestone**
— so you never pay its cold-start during development, and its one open risk (cold-start on hot
commands) gets validated when you package, not baked into the design. Build so that adopting Burrito
is **config-only, no rewrite**:
- **One clean entrypoint** (e.g. `VzBeam.CLI.main/1`) that an escript today and Burrito later both
  wrap.
- **Read argv through a thin shim** — `System.argv()`/escript in dev; Burrito passes args via its own
  helper (confirm the exact entry/arg API when you wire it). Don't scatter `System.argv()` around.
- **No `Mix.*` at runtime** — it isn't present in a release/Burrito build. Use `Application` config +
  `Application.app_dir/2`.
- **Locate the Swift sidecar at runtime, never at a build path** — a packaged binary (Burrito
  extracts to a versioned cache dir) won't find a dev path. Resolve via env var → config → `$PATH` →
  alongside-the-binary, at run time.

**Entitlement wrinkle (true regardless of Burrito):** the VZ-linking Swift binary must be
**separately codesigned with `com.apple.security.virtualization`** (fact #10) — Burrito can't carry
that entitlement. So the shipped deliverable is always **two artifacts**: the Elixir CLI (escript in
dev → Burrito binary at release) **+** a signed Swift `vz` sidecar. How the sidecar is shipped/located
is open question #2.

---

## Why not `swift-erlang-actor-system` (recorded, in case it resurfaces)

It's a runtime for **Swift distributed actors** over Erlang's **`erl_interface`** C-node API — a Swift
process joins the BEAM cluster as a node and exchanges GenServer-style calls bidirectionally. Genuinely
elegant **if** vzbeam were a persistent daemon supervising a fleet of VMs as distributed actors.

It's **out** because: (1) vzbeam is a one-shot CLI → no persistent BEAM node for a Swift node to
connect to; (2) it adds an `erl_interface` C-node dependency + epmd/cookie/node-name machinery +
Burrito-bundling complexity; (3) it's **pre-release** (~190 stars, zero releases) — a poor bet for the
critical path. The plain subprocess boundary gives everything a macOS-only, ≤2-VM, one-shot tool
needs. Revisit only if a persistent fleet daemon ever earns its place *and* the library has matured.

---

## Open questions to resolve in brainstorming

(The big structural ones — daemon-vs-CLI, interop, Linux, bridged — are settled under "Scope
decisions." What's left:)

1. **Burrito — packaging stage only (deferred):** when you package, validate cold-start latency on
   hot commands (`ssh`/`ip`) and macOS codesigning/notarization. It does **not** block building the
   tooling — keep the design Burrito-agnostic until then (see "Packaging").
2. **Sidecar packaging:** ship the signed Swift `vz` binary alongside the CLI, build+sign it on first
   run, or expect it on `$PATH`? (Ties into "Packaging".)
3. **Primary target:** optimize first for the **agent-sandbox** loop or the **throwaway-desktop**
   experience? (They share the engine but pull the UX in different directions.)
4. **Config story:** replace the hand-rolled TOML with what — and what becomes configurable beyond
   `cpu`/`mem_gb`/`disk_gb`?

---

## How to work (project conventions)

- **Brainstorm → spec → `writing-plans` → execution.** Use the superpowers skills. **Do not write
  product code during brainstorming.** Confirm the spec and plan with me before building.
- **Validate, don't assume.** Prove any framework/tooling behavior with a minimal, **non-mutating**
  throwaway test before relying on it. State plainly what's validated vs. an open question. (This
  rule exists because confidently-wrong assumptions have wasted real time.)
- **Knowledge-base first.** Before asserting how a tool/CI/system behaves, check
  `~/.claude/knowledge-base/index.md` and the relevant topic file; record newly validated facts
  there with their proof. Relevant existing topics: `virtualization-framework.md`, `macos-cp.md`
  (`cp -c` CoW), `tart.md` (clone/stop pitfalls), `bash.md`.
- **Reference implementation:** `~/src/sbx` (Swift core in `Sources/sbx-vz/`, orchestration in
  `bin/sbx`, design spec in `docs/superpowers/specs/2026-06-17-sbx-vm-sandbox-design.md`). Read it
  for ground truth; don't assume the summaries above are complete.
- **Don't over-engineer.** Minimal scope to the goal; ask before adding extras.

## Start by

Invoking the `brainstorming` skill and working the remaining open questions with me — **primary
target** (agent-sandbox vs throwaway-desktop) and the **config story**. Build the CLI as a plain
`mix`/escript project; **Burrito comes later, at packaging** (see "Packaging"). Then propose a spec.
