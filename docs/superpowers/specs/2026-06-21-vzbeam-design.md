# vzbeam — Design Spec (MVP)

- **Status:** Draft for review (v3 — Codex review + simplifications through 2026-06-21)
- **Date:** 2026-06-21
- **Nature:** Clean-room rewrite of `sbx` (reference implementation; not ported line-by-line)

---

## 1. Summary

`vzbeam` spins up throwaway **macOS** VMs on Apple Silicon, built **directly on Apple's
`Virtualization.framework`** — no third-party VM runtime (no Tart/Lima/UTM) and **no paid Apple
Developer account** (ad-hoc codesign + one entitlement). It is a clean-room rewrite of `sbx` that
keeps **Swift to only the code that must link `Virtualization.framework`** and moves everything else
into an **Elixir** CLI.

This spec covers the **MVP**: composable primitives plus the irreducible Swift core. The one-shot
`sandbox` composite verb, a real `extract` command, base-as-code provisioning, an attached/`--attach`
run mode, a global config file, and Burrito packaging are **explicit non-goals** for this iteration
(§16).

---

## 2. Goals / Non-goals

**Goals**

- **Minimal Swift** — only VZ-linking code: `image-info`, `restore`, `run`, `reid`.
- **Elixir owns orchestration** — filesystem, SSH, lease parsing, lifecycle *decisions*, process
  management, concurrency/locking, 2-VM-cap enforcement, **all file I/O**.
- **Co-equal engine** — GUI and headless are thin frontends; no UX assumptions leak into the engine.
- **JSON everywhere** — one format across the Swift⇄Elixir wire, the per-bundle manifest, the
  `vm.pid` runtime file, and the cached-image index; one parser (Jason).
- **Burrito-agnostic** — develop as a plain `mix`/escript project; adopting Burrito later is
  *config-only*.
- **Preserve every validated framework behavior** carried over from `sbx` (§12).

**Non-goals (this spec):** `extract`, the `sandbox` composite verb, base-as-code provisioning, an
attached/`--attach` run mode, a **global config file** (built-in defaults suffice — §6), config-level
named bases, a default `--share` (waits until sharing is in use), Burrito packaging, bridged
networking, Linux guests, a daemon.

---

## 3. Architecture — three layers

```
            argv in  ┌─────────────────────────────┐  JSON-lines stdout
   ┌──────────────── │      Elixir CLI (engine)     │ ◀───────────────┐
   │  System.cmd /   │  lifecycle · clone · rm · ls │                 │
   │  detached spawn │  ip/leases · ssh · stop/kill │                 │
   ▼                 │  cap · run.lock · ALL file IO│                 │
┌─────────────┐      │  built-in defaults           │                 │
│ Swift `vz`  │      └─────────────────────────────┘                 │
│  sidecar    │            ▲ thin frontends: `run --gui` / `--headless`│
│ image-info  │            │ differ only by flags (both detach)        │
│ restore/run │ ───────────┴───────────────────────────────────────────┘
│   /reid     │
│ (links VZ,  │   The ONLY component that links Virtualization.framework
│  ad-hoc     │   and needs com.apple.security.virtualization.
│  signed)    │
└─────────────┘
```

- **Swift `vz` sidecar** — the only component linking `Virtualization.framework`; ad-hoc signed with
  `com.apple.security.virtualization`. Subcommands: `image-info`, `restore`, `run`, `reid`. Stateless
  beyond the bundle it is pointed at. **Never reads or writes config/state files** — inputs via argv,
  results as JSON lines on stdout.
- **Elixir engine** — bundle lifecycle, CoW clone, `rm`, `ls`, `ip`/lease parsing, `ssh`, stop/kill
  *decisions*, concurrency locking, 2-VM-cap enforcement, sidecar process management, `vm.pid`
  ownership, built-in defaults, and **all filesystem I/O**.
- **Thin frontends** — the CLI verbs. GUI vs headless differ only by flags passed through to
  `vz run`; both detach; neither path is privileged.

---

## 4. The Swift⇄Elixir boundary

Interop is a **plain subprocess** (settled: *no* `swift-erlang-actor-system` — a one-shot CLI has no
persistent BEAM node for a Swift C-node to attach to).

- `System.cmd` (captured) for short-lived `image-info` / `restore` / `reid`.
- A fully **detached spawn** for `run` (§8). The MVP has **no attached/Port mode** — `run` always
  backgrounds; deferred.

**Wire protocol — JSON Lines on stdout.** One JSON object per line, each with a `type` field. Swift
writes *only* machine-readable JSON to **stdout**; human-readable logs go to **stderr**.

```jsonc
// image-info
{"type":"image","version":"26.5.1","build":"25F80","url":"https://…","source":"latest"}
// restore
{"type":"progress","fraction":0.42}
{"type":"restored","machineIdentifier":"<b64>","hardwareModel":"<b64>","macAddress":"5e:..","version":"26.5.1","build":"25F80"}
// reid
{"type":"reid","machineIdentifier":"<b64>","macAddress":"5e:.."}
// run
{"type":"started","pid":4321}
{"type":"guest_stopped"}        // then the process exits 0
{"type":"error","domain":"VZErrorDomain","code":6,"message":"maximum supported number of active virtual machines reached"}
```

**Decoder rules (robustness — Codex #10).** Newline-buffered; reject over-long lines (cap, e.g.
1 MiB); EOF with an unterminated line or *before any terminal event* = protocol error; a non-empty
**stderr tail** is preserved and surfaced on failure; **terminal precedence** = a `{"type":"error"}`
or non-zero exit dominates a prior `started`. Unknown `type` values are ignored (forward-compatible).

**Ownership — the two field-sets are disjoint:**

- **Swift mints + emits** the *opaque* identity fields: `machineIdentifier`, `hardwareModel`,
  `macAddress`. Elixir stores them **verbatim** and passes them back as `run` inputs; it never parses
  or edits the bytes.
- **Elixir owns** the human-meaningful fields: `name`, `cpuCount`, `memoryBytes`, `base`, `image`,
  `createdAt`. Swift receives cpu/mem as argv inputs and never persists them.
- `reid` is a **wholesale replace** of `{machineIdentifier, macAddress}`, sourced from Swift — never
  an Elixir edit.

---

## 5. Data model

`$VZBEAM_HOME` (default `~/.local/share/vzbeam`; the **single** relocatable storage switch) layout:

```
$VZBEAM_HOME/
  run.lock                 # host-wide flock for cap-check + spawn (§8)
  keys/id_ed25519[.pub]    # baked SSH keypair
  cache/ipsw/              # cached restore images + index.json (version/build per IPSW)
  bin/vz                   # built + ad-hoc-signed Swift sidecar (§10)
  <name>/                  # one bundle per VM, cloned as a unit
    config.json            # per-bundle manifest
    disk.img               # sparse main disk
    aux.img                # VZMacAuxiliaryStorage (NVRAM)
    vm.pid                 # JSON runtime state while running (Elixir-owned)
    run.log                # the run's stdout/stderr + startup handshake
```

There is **no global config file** (§6). **Per-bundle manifest** (`<name>/config.json`). A **base**
(restored) has `base: null`; a **clone** sets `base` and inherits the `image` block:

```json
{
  "schemaVersion": 1,
  "name": "base",
  "base": null,
  "image": { "version": "26.5.1", "build": "25F80", "source": "latest" },
  "machineIdentifier": "<base64>",
  "hardwareModel": "<base64>",
  "macAddress": "5e:aa:bb:cc:dd:ee",
  "cpuCount": 4,
  "memoryBytes": 8589934592,
  "createdAt": "2026-06-21T00:00:00Z"
}
```

**`vm.pid`** is JSON, not a bare integer, so liveness survives PID reuse (Codex #8):

```json
{ "pid": 4321, "startedAt": "2026-06-21T00:01:02Z", "bundle": "dev" }
```

Liveness = pid alive **and** the process start-time matches `startedAt` (via `ps`). A pid present but
dead/mismatched ⇒ treated as stopped and lazily cleaned by the next Elixir command.

**Atomic writes (Codex #12):** every manifest / `vm.pid` write is write-temp-then-rename. `new`
clones into a `.pending` temp dir, runs `reid`, writes the manifest, then renames to the final
`<name>` — so a crash can never leave a half-cloned bundle with the base's identity. Unknown JSON keys
are preserved on read-modify-write (Codex #13).

---

## 6. Defaults & sizing (no config file)

Built-in default constants — **no global config file in the MVP**:

```
cpu = 4    mem_gb = 8    disk_gb = 64    resolution = 1920x1200    ssh_user = admin
```

Resolution for any value: **CLI flag > built-in default**. Defaults are printed in `--help` and
**echoed at creation** ("creating cpu=4 mem=8G disk=64G — override with `--cpu/--mem-gb/--disk-gb`").
The per-bundle manifest records the *chosen* values for that VM. A config file (and a `config` verb)
returns only when a real recurring preference earns it — e.g. a default `--share` once sharing is in
use (§16).

---

## 7. CLI surface (MVP)

**Elixir CLI**

| Verb | Behavior |
|---|---|
| `fetch <latest\|PATH>` | Download + cache an IPSW (resolves `latest` via `image-info`, records version/build in `cache/ipsw/index.json`). Image acquisition only. |
| `new <name> <base>` | Clone a **cleanly-stopped** base (APFS `cp -Rc`, CoW) then `reid` (fresh MAC + machine identity). **`<base>` is required** (no default). Inherits the base's `image` block, sets `base: <base>`. |
| `new <name> --image <latest\|PATH>` | **Restore** a cached image into a fresh base (`vz restore`); auto-`fetch` if uncached. Mutually exclusive with a positional base. |
| `run <name> [--gui\|--headless] [--resolution WxH] [--share tag=/path]` | Boot the VM — **always detaches/backgrounds** (§8). `--gui` adds a window; `--headless` (default) does not. First `run --gui` on a fresh base is where Setup Assistant happens (§8 note). |
| `stop <name>` / `kill <name>` | Graceful guest `shutdown -h now` over SSH / force power-off via signal (§8). |
| `ls` | `NAME · STATUS · BASE · OS(version+build) · IP · CPU · MEM · DISK · PATH`. |
| `images` | Cached IPSWs with version/build (from `cache/ipsw/index.json`). |
| `ip <name>` | DHCP lease lookup by the bundle's MAC (pure parsing). |
| `rm <name>` | Delete the bundle. Refuses a running VM without `--force` (then stops it first). No base special-casing — CoW clones are independent (spike-proven), so deleting a base orphans nothing. |
| `ssh <name> [-- cmd…]` | Thin key-based SSH convenience (resolves IP + baked key); documents the one-time key-install / `mount_virtiofs` flow. |

**Swift `vz` sidecar:** `image-info` (resolve `latest` / read a local IPSW's version+build via
`VZMacOSRestoreImage`), `restore` (`VZMacOSInstaller`), `run`, `reid`. (`ip`, lease parsing, and all
manifest I/O are pure orchestration → Elixir.)

**Lightweight named bases for free:** because `<base>` is any bundle name, any restored bundle is a
clone source (`new test ventura`). No config machinery needed for the common case.

---

## 8. Run lifecycle

**`run` always detaches** (GUI and headless both background — `--gui` merely adds a window). The
engine spawns `vz run` in its **own session** (`setsid`), stdin/stdout/stderr redirected to `run.log`
(never a live pipe), so it survives the BEAM/escript exit and ignores `SIGHUP`. The engine **tails
`run.log` for a bounded startup handshake** — `started` (capture pid) / `error` / timeout — then
atomically writes `vm.pid` and returns. `run.log` is the startup handshake + a human log
(`tail -f` for live events); it is **not** a post-startup protocol channel — later commands derive
status from `vm.pid` liveness + DHCP leases (poll-based, accepted).

> The `setsid`/fd-redirection/SIGHUP/parent-exit survival mechanics are **validatable on this dev
> box** with a dummy long-running child — no hypervisor needed. **Real-HW checks:** that a detached
> process reliably shows the AppKit `VZVirtualMachineView` window, and the VM-specific behaviors
> below (§13).

**Lifecycle states (Elixir-owned — Codex #11):** `starting → started(host process/VM up) →
networking(bridge100 present) → ssh_ready(SSH answers)`. `started` ≠ reachable; reachability is
derived by the engine via leases + an SSH poll, not from a single Swift event.

**Stop / kill (Codex #1):**

- **`stop`** = graceful = guest-side `shutdown -h now` over SSH (macOS ignores `requestStop()`
  headless, fact #4); the sidecar's `guestDidStop` delegate calls `exit(0)`, freeing the guest's RAM.
- **`kill`** = force = the engine **sends a signal** to the `vz run` pid; the sidecar traps it and
  calls `VZVirtualMachine.stop()`. No new Swift subcommand — signals are the control path. `SIGKILL`
  (untrappable) is the last-resort fallback only.

**Concurrency & the 2-VM cap (Codex #6, #7):**

- A host-wide **`$VZBEAM_HOME/run.lock`** (flock) wraps **cap-check → spawn → `vm.pid` write** as one
  critical section; live pids are re-counted *inside* the lock to defeat TOCTOU between concurrent
  `run`s.
- The pre-check is **UX only**. The framework's `VZError Code=6` is authoritative and is **always**
  mapped to the same typed cap error (external VZ users / stale state can still trip it). (fact #1)

**Other framework-mandated behaviors (preserve exactly — §12):**

- Headless networking uses `RunLoop.main.run()` on the main queue — **never** `dispatchMain()`
  (fact #2). A graphics device is attached even headless (fact #3).
- **IP discovery:** parse `/var/db/dhcpd_leases` by the bundle's MAC. `bridge100` is the readiness
  tell (fact #8) — don't conclude "broken" from a too-short SSH poll.
- **Never hard-`pkill`** a running guest (fact #9); **clone only a cleanly-stopped base** (fact #5).

**First-boot (facts #6, #7) — decided:** `new <name> --image` restores a bootable but *unconfigured*
base. The **first `run --gui`** is where you complete Setup Assistant (create `admin`, enable Remote
Login) — inherently manual GUI. **Key install is a `run`-phase concern:** right after first boot, a
documented one-time `ssh-copy-id` (the CLI prints the exact command via `ip`/`ssh`) installs the baked
key. This persists on disk and is inherited by all clones — paid once ever on the base.

---

## 9. virtiofs file share

`--share tag=/host/path` attaches a **virtiofs** shared directory (read-write, round-trips both
directions). Split on the **first** `=`:

- **tag** — the mount label the guest uses (`mount_virtiofs <tag> <mountpoint>`); an identifier, not a
  path.
- **/host/path** — the host directory exposed into the guest.

**Validated tag rules (probed on this macOS 26 SDK):** non-empty, **≤ 36 bytes UTF-8**; slashes and
spaces are permitted; the tag side cannot contain `=` (the flag delimiter).

Elixir parses + validates (tag rules, host dir exists) and passes `tag` + absolute path to Swift;
Swift builds `VZVirtioFileSystemDeviceConfiguration` + `VZSingleDirectoryShare(VZSharedDirectory(url:,
readOnly:false))` and runs `.validate()`. **With `extract` deferred, `--share` is the artifact
round-trip mechanism — a first-class, tested MVP feature** (Codex #17); the guest-side `mount_virtiofs`
flow is documented as part of `run`/`ssh`.

---

## 10. Sidecar provisioning + location

**Provisioning (Option A):** a `mix`/make task compiles the Swift core and **ad-hoc-signs** it (with
the entitlement) into `$VZBEAM_HOME/bin/vz`. `swift build` drops the entitlement on every relink
(fact #10), so the build **re-signs every time**. Each machine (dev box *and* real-HW box) builds +
signs its own — no notarization, always matches host arch/OS.

**Auto-build is dev-only (Codex #15):** in a release/Burrito build there is no toolchain assumption
and no `Mix.*` at runtime; a missing sidecar yields a clear "run `vzbeam build-sidecar`" error.

**Location at runtime:** `env VZBEAM_VZ` → alongside the CLI binary → `$PATH`. **Provisioning is
decoupled from location**, so a future switch to "ship prebuilt + signed" is config-only.

**Version locking has teeth (Codex #14, #16):** the engine calls `vz --version` (a protocol-version
report) before use and **refuses an incompatible sidecar** — important for the `$PATH`/env paths.
Sidecar discovery, the version check, and the build/install UX are **MVP features**, not
packaging-time work.

---

## 11. Packaging (deferred — Burrito)

Build Burrito-agnostic now: one clean entrypoint (`VzBeam.CLI.main/1`); argv via a thin shim; **no
`Mix.*` at runtime** (use `Application` config + `Application.app_dir/2`); locate the sidecar at
runtime, never a build path (§10).

**Entitlement split is permanent:** Burrito wraps the *Elixir* side; the VZ-linking `vz` is *always* a
separately-signed artifact → the deliverable is **two artifacts**. What changes at Burrito time
depends only on audience:

| Audience | Sidecar | Signing | Paid account? |
|---|---|---|---|
| **Personal / own machines** (current premise) | Keep Option A (build locally) | ad-hoc | **No** |
| **Distribute to others / toolchain-less Macs** | Must prebuild | ad-hoc + `xattr -d com.apple.quarantine` (friction) **or** Developer ID + notarize (clean UX) | Only for the clean-UX path |

The virtualization entitlement is **non-restricted** (works with ad-hoc *and* Developer ID; unlike
`com.apple.vm.networking`, no Apple-approval gate). **Validate at packaging time:** cold-start latency
on hot commands (`ssh`/`ip`) and the codesign/notarization mechanics.

---

## 12. Validated facts & gotchas that must survive

**Validated *here* (this machine, macOS 26.5.1):**

- Ad-hoc codesign + `com.apple.security.virtualization` works; entitlement embeds and the binary runs
  (core of fact #10). ✔
- Swift links `Virtualization.framework`; `VZMacMachineIdentifier`/`VZMACAddress` mint in-memory
  (`reid` works without a hypervisor). ✔
- `VZMacOSRestoreImage` exposes `operatingSystemVersion` + `buildVersion` + `url` (the `image` block
  is populatable). ✔
- virtiofs tag rules: non-empty, ≤ 36 UTF-8 bytes (§9). ✔
- `cp -Rc` clones survive deletion of their source, content intact (§7 `rm`). ✔
- Nested virtualization is **Linux-guests-only**; `VZMacPlatformConfiguration` has no nested knob →
  macOS-in-macOS is impossible on Apple Silicon. ✔

**Trust the prompt; re-validate on real HW (boot-dependent):**

1. ≤ 2 macOS VMs simultaneously; a third fails `VZError Code=6` (fact #1).
2. Headless networking needs `RunLoop.main.run()`, not `dispatchMain()` (fact #2).
3. Graphics device attached even headless (fact #3).
4. macOS ignores `requestStop()` headless → guest `shutdown -h now` + `guestDidStop` exit (fact #4).
5. Clone only a cleanly-stopped base (fact #5).
6. Regenerate **both** MAC and machine identity per clone (fact #6).
7. First boot needs the GUI once for Setup Assistant (fact #7).
8. `bridge100` is the networking-readiness tell (fact #8).
9. Never hard-`pkill` a running guest (fact #9).

---

## 13. Validation environment reality

This host reports `kern.hv_support=0` / `kern.hv_vmm_present=1` — it is a **macOS guest** and cannot
run VZ guests of its own (macOS nested virt is unsupported; §12). Therefore:

- **Green bucket — validatable here:** the entire Elixir engine, arg parsing, defaults, JSON wire
  protocol + decoder, lease parsing (synthetic fixtures), `reid`, `image-info` shape, `cp -Rc`
  clone independence, the Swift build + codesign loop, sidecar location/version logic, **and the
  detached-process daemonization harness** (with a dummy child).
- **Boot-dependent — needs bare-metal Apple Silicon** (the M1 Max, or any physical M-series Mac):
  `restore`, `run`, the detached AppKit window, the 2-VM cap, headless `RunLoop` networking,
  `bridge100`, `stop`/`kill`, clone fidelity, full first-boot. **Two machines in the loop.**

---

## 14. Error handling

- **2-VM cap:** lock-guarded pre-check + authoritative `VZError 6` mapping (§8).
- **Clone guard:** refuse `new` when the base is running (fact #5); `new <base>` required (no default).
- **Share validation:** tag rules + host dir existence, in Elixir, before launch.
- **Images:** `fetch`/`--image latest` failures (network, catalog) surface as actionable errors;
  checksum/size sanity on cached IPSWs.
- **Sidecar:** not-found → "build the sidecar" with the resolution order; version mismatch → refuse.
- **Subprocess:** non-zero exit / `{"type":"error",…}` map to typed Elixir errors with the VZ
  domain/code preserved; stderr tail attached (§4).
- **Stale state:** `vm.pid` present but pid dead / start-time mismatch → treat as stopped, clean up.

---

## 15. Testing strategy

- **Elixir engine (runs here, CI on this box):** arg parsing, defaults, manifest + `vm.pid` JSON
  round-trip, lease parsing fixtures, sidecar location/version logic, JSON-lines decoder
  (partial/oversize/EOF/precedence), cap counting under the lock, error mapping, the **detach harness**
  (dummy child survives parent exit). The bulk of the value over the zsh wrapper.
- **Swift (runs here):** `reid` minting; `image-info` shape; config `.validate()` for share/tag.
- **Boot-dependent integration (gated, real HW):** restore→run→ssh→stop/kill→rm, clone concurrency,
  headless networking, first-boot. Documented suite, run on the M-series Mac at the build milestone.

---

## 16. Deferred non-goals (on the record)

- `extract` command (artifacts round-trip via `--share` for now).
- `sandbox` composite verb (teardown trigger underdefined without `extract`; primitives compose).
- **Attached/`--attach` run mode** (MVP `run` always detaches; `tail -f run.log` for live events).
- **Global config file + `config` verb** (built-in defaults suffice — §6). A config file returns only
  when a recurring preference earns it — notably a **default `--share` once sharing is in use**.
- Base-as-code provisioning; **config-level** named bases (positional `<base>` covers the common case).
- Live in-guest version reporting (`sw_vers` over SSH) — the manifest records the *restore-image*
  version; "as-built vs current" drift is a later add.
- Burrito packaging (§11) and any notarization/distribution work.
- Bridged networking, Linux guests, a persistent daemon — settled out of scope.

---

## 17. Remaining open questions

None outstanding — the design is ready for an implementation plan. (Burrito-time items in §11 are
explicitly deferred to the packaging milestone.)
