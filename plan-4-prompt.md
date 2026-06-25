# vzbeam — Plan 4 (Swift `vz` sidecar) handoff (paste into a fresh session)

You are continuing **vzbeam**, a tool that spins up throwaway **macOS** VMs on Apple Silicon built
directly on Apple's **Virtualization.framework** (no third-party runtime, no paid Apple Developer
account). It is split into a **minimal Swift `vz` sidecar** (the only code that links VZ — **this is
what Plan 4 builds**) and an **Elixir CLI engine** (Plans 1–3, merged to `main`). This is the **same
repo** — so **read the spec, the fake sidecar, and the engine code rather than taking anything below on
faith** (validate, don't assume).

Three memory files auto-load for this project: `vzbeam-validation-environment`,
`vzbeam-collaboration-style`, `vzbeam-plan-progress`. Read them.

## Your mission

**Brainstorm, then (after we agree on a spec + plan) implement Plan 4 — the Swift `vz` sidecar:** the
subcommands `image-info`, `restore`, `run`, `reid`, plus **provisioning** (a build/codesign task that
drops an ad-hoc-signed `vz` into `$VZBEAM_HOME/bin/`) and the **`--version` protocol handshake**. Do
**not** write product code during brainstorming. Start with the `brainstorming` skill, confirm a spec
and plan with me, then execute (note the validation reality below — execution is **not** the green-
bucket TDD flow Plans 1–3 used; much of it is **manual on real hardware**).

## The defining constraint: Plan 4 is HARDWARE-GATED (read this first)

Plans 1–3 were "green bucket here, HW-gated deferred." **Plan 4 inverts that — the HW-gated work *is*
the deliverable.** This build host is a **virtualized** macOS box (`kern.hv_support=0`) and **cannot
boot VZ guests** (`VZVirtualMachine.start()` fails; macOS-in-macOS is impossible on Apple Silicon — see
`vzbeam-validation-environment`). So:

- **Validatable on THIS build host (green-ish):** Swift compiles + links `Virtualization.framework`;
  **ad-hoc codesign + `com.apple.security.virtualization`** embeds and the binary runs (proven on macOS
  26.5.1 — spec §12); **`reid`** mints `VZMacMachineIdentifier` + `VZMACAddress` purely in-memory (no
  hypervisor — proven §12); **`image-info`** reads `VZMacOSRestoreImage` `operatingSystemVersion` /
  `buildVersion` / `url` (proven §12); config `.validate()` for `--share` tag rules; the **provisioning
  task** (build → re-sign → place in `$VZBEAM_HOME/bin/vz`); the **`--version` check**; and **swapping
  the engine from the fake `vz` to the real one** (`VZBEAM_VZ`/discovery).
- **NEEDS bare-metal Apple Silicon (an M-series Mac):** `restore` (`VZMacOSInstaller`), `run`/**boot**,
  the detached AppKit `VZVirtualMachineView` window, **headless `RunLoop.main.run()` networking**,
  `bridge100`, the **2-VM cap (`VZError 6`)**, real `stop`/`kill` of a guest, first-boot Setup
  Assistant, and the full `run → ssh → stop → rm` round-trip.

**Confirm with me early which machine you're on.** `reid` / `image-info` / provisioning / the version
handshake can start here; everything boot-dependent must be developed and verified on the M-series Mac.
A green compile + sign on this box does **not** prove a VM boots.

## What's already on `main` (Plans 1–3 — the engine is DONE; don't re-create)

The full Elixir engine, **100 tests green** (`mix test`), `mix escript.build` → `./vzbeam`. Verbs `ls`,
`ip`, `images`, `fetch`, `new` (clone + restore), `rm`, **`run`, `stop`, `kill`, `ssh`**, host-wide
`run.lock`, the 2-VM cap, detached spawn, `run.log` handshake, and a `Port`-streamed `restore`
transport — **all built against a FAKE `vz`** (`test/support/fake_vz`). The engine never boots anything;
it orchestrates a sidecar that doesn't exist yet. **Plan 4 makes that sidecar real.**

You can drive the whole engine today against the fake (point `VZBEAM_VZ` at `test/support/fake_vz`):
`fetch <PATH>` → `new base --image <PATH>` → `new dev base` → `run dev` → `ls` (shows running) →
`kill dev` → `rm`. The 2-VM cap refuses a 3rd `run`. (`stop`/`ssh` need a reachable guest, so they only
reach "no DHCP lease" against the fake.)

## The FROZEN wire contract (the fake `vz` + the 100 tests define it — match it byte-for-byte)

The real sidecar must emit **exactly** what `VzBeam.Protocol` / `VzBeam.Sidecar` / the verbs already
parse. **`test/support/fake_vz` is your reference oracle** — read it. Rules (spec §4): **one JSON object
per line on stdout, newline-terminated**; **human logs go to stderr** (stdout is JSON-only or you
corrupt the decoder); unknown `type`s ignored; **an `{"type":"error"}` event or non-zero exit dominates
a prior `started`/terminal**. Per subcommand:

```jsonc
// vz --version          (engine refuses an incompatible protocol — VzBeam.Sidecar @protocol_version 1)
{"type":"version","protocol":1}
// vz image-info <latest|PATH>
{"type":"image","version":"26.5.1","build":"25F80","url":"https://…","source":"latest"}
// vz reid               (mints a fresh identity; hardwareModel is NOT reissued — it's image-bound)
{"type":"reid","machineIdentifier":"<b64>","macAddress":"5e:…"}
// vz restore …          (progress streams via a Port; then the terminal)
{"type":"progress","fraction":0.42}
{"type":"restored","machineIdentifier":"<b64>","hardwareModel":"<b64>","macAddress":"5e:…","version":"26.5.1","build":"25F80"}
// vz run …              (emit started, then idle; on guest stop OR a trapped SIGTERM, emit guest_stopped, exit 0)
{"type":"started","pid":4321}
{"type":"guest_stopped"}
{"type":"error","domain":"VZErrorDomain","code":6,"message":"maximum supported number of active virtual machines reached"}
```

**Identity ownership (spec §4):** Swift **mints + emits** the opaque `machineIdentifier`,
`hardwareModel`, `macAddress` (base64/MAC strings); Elixir stores them **verbatim** and passes them back
as `run` inputs. `reid` is a wholesale replace of `{machineIdentifier, macAddress}` (hardwareModel
stays). Swift **never reads or writes config/state files** — inputs via argv, results as JSON lines.

## The exact argv the engine passes today (verify in the code) — and the SEAMS to reconcile FIRST

Read `lib/vzbeam/commands/run.ex` (`build_argv/5`), `lib/vzbeam/commands/new.ex` (the `restore` deps
map), and `lib/vzbeam/sidecar.ex` (`image_info`/`reid`/`restore`/`stream`/`call`). What the engine
currently sends:

- `image-info <latest|PATH>`
- `reid`
- `restore --ipsw <path> --disk <path> --aux <path> --disk-size <bytes> --cpu <n> --mem <bytes>`
- `run --bundle <dir> --mac <mac> --cpu <n> --mem <bytes> (--gui|--headless) --resolution <WxH> [--share <tag> <abspath>]`

**Two genuine seams the fake never exercised — settle these during brainstorming (a small Plan-3-side
engine change may be cleaner than contorting Swift):**

1. **`run` is missing the identity inputs.** `build_argv` passes only `--mac` — **not**
   `machineIdentifier` or `hardwareModel`, which `VZMacPlatformConfiguration` *requires* to construct
   the VM. Spec §4 says the engine passes identity back to Swift, so **extend `build_argv` to pass
   `--machine-id <b64> --hardware-model <b64>`** (both live in the bundle's `config.json`, already read
   into the manifest). The alternative — Swift reading `config.json` from `--bundle` — **contradicts §4**
   ("Swift never reads config/state"). Decide and reconcile before building `run`.
2. **`run` uses `--bundle <dir>` but `restore` uses explicit `--disk`/`--aux`.** Pick one convention for
   how disk/aux paths reach the sidecar (passing `--disk`/`--aux` explicitly to `run` too keeps Swift
   ignorant of bundle layout and is consistent with `restore`).

Whatever you change on the engine side, **keep the 100 tests green** and update `fake_vz` + the affected
tests in lockstep (the fake is the contract).

## What Plan 4 builds (spec §3, §7, §10)

- **`image-info <latest|PATH>`** — resolve `latest` (Apple catalog) or read a local IPSW's
  version/build/url via `VZMacOSRestoreImage`. (Catalog endpoint was **unreachable** last session — spec
  §12; the local-PATH path is testable here.)
- **`restore`** — `VZMacOSInstaller` installs the IPSW into `disk.img`, creates `aux.img`
  (`VZMacAuxiliaryStorage`), mints identity, streams `progress`, emits `restored`. **HW-gated.**
- **`run`** — build the VM from the bundle (identity + disk + aux + cpu/mem + gui/headless + resolution
  + share), `start()`, emit `started{pid}`. **`--headless` networking MUST use `RunLoop.main.run()` on
  the main queue — never `dispatchMain()`** (fact #2); a graphics device is attached **even headless**
  (fact #3). **Trap `SIGTERM` → `VZVirtualMachine.stop()`** (the engine's `kill` control path — fact #9)
  → emit `guest_stopped`, `exit(0)`. macOS **ignores `requestStop()` headless** → the engine's `stop`
  drives a guest-side `shutdown -h now` over SSH and the `guestDidStop` delegate calls `exit(0)` (fact
  #4). **Own session:** Plan 3 decided to let the sidecar **`setsid()` itself** on startup (the engine
  only `nohup`s); honor that. **HW-gated.**
- **`reid`** — mint a fresh `VZMacMachineIdentifier` + `VZMACAddress`, emit them. **Testable here.**
- **Provisioning (spec §10, Option A):** a `mix`/make task compiles the Swift core and **ad-hoc-signs**
  it with the entitlement into `$VZBEAM_HOME/bin/vz`. `swift build` **drops the entitlement on every
  relink** (fact #10) → **re-sign every build**. Auto-build is **dev-only**; a release/Burrito build has
  no toolchain and must emit a clear "run `vzbeam build-sidecar`" error (Codex #15). The engine already
  locates the sidecar (`VZBEAM_VZ` → `$VZBEAM_HOME/bin/vz` → alongside-CLI → `$PATH`) and
  **version-checks** it (`vz --version` → protocol 1) — see `VzBeam.Sidecar.locate/0` + `check_version/1`.
- **`--version`** — report `{"type":"version","protocol":1}`. The engine refuses a mismatch.

## Validated facts / gotchas Plan 4 MUST implement (spec §12)

- ≤ 2 macOS VMs simultaneously; a 3rd fails **`VZError Code=6`** → emit it as an `error` event (the
  engine maps it to the authoritative cap error — fact #1).
- Headless networking: **`RunLoop.main.run()`**, not `dispatchMain()` (fact #2). Graphics device
  attached even headless (fact #3).
- macOS ignores `requestStop()` headless → guest `shutdown -h now` + `guestDidStop` exit (fact #4).
- Clone only a cleanly-stopped base; regenerate **both** MAC and machine identity per clone (the engine
  enforces "stopped"; Swift provides `reid`) (facts #5, #6).
- First boot needs the **GUI once** for Setup Assistant (create `admin`, enable Remote Login); the
  documented one-time `ssh-copy-id` then installs the engine's baked key (fact #7).
- `bridge100` is the networking-readiness tell (fact #8) — the engine polls; don't fight it.
- **Never hard-kill a guest** — the engine sends a trappable `SIGTERM` first; your trap must call
  `VZVirtualMachine.stop()` (fact #9).
- Ad-hoc codesign + `com.apple.security.virtualization` is **non-restricted** (works ad-hoc; no
  Apple-approval gate) — proven here (fact #10).

## How to work (project conventions — see `vzbeam-collaboration-style`)

- **Brainstorm → spec (`docs/superpowers/specs/`) → `writing-plans` → execution → reviews →
  `finishing-a-development-branch`.** Confirm the spec and plan with me before building.
- **Validate, don't assume.** Prove framework/OS/tooling behavior with a minimal spike before relying on
  it. **State what's validated-here vs HW-gated** for every claim. The hardware split is the whole game
  this plan.
- **Resolve mechanical/implementation forks yourself via spike + a recommendation** — don't poll me with
  multiple-choice questions a spike can settle; reserve questions for genuine product/scope calls.
- **Use Codex as an independent review point** at the spec milestone and on the riskiest mechanism
  (the `run` boot path + the signal-trap/lifecycle) before it hardens.
- **YAGNI hard** — minimal Swift surface (only what links VZ); justify any added subcommand/flag.
- Branch off `main`; per-task commits; merge (`--no-ff`) only when I approve.
- **Execution flow differs from Plans 1–3:** the boot-dependent tasks are NOT green-bucket TDD. Expect a
  documented **manual integration suite run on the M-series Mac** (spec §15) plus whatever Swift unit
  tests *can* run here (`reid` minting, `image-info` shape, config `.validate()`). Plan accordingly.

## References

- Design spec: `docs/superpowers/specs/2026-06-21-vzbeam-design.md` — esp. **§3** (three layers / Swift
  responsibilities), **§4** (wire protocol + identity ownership), **§7** (CLI surface — the sidecar row),
  **§8** (run lifecycle — what the engine expects from `run`/`stop`/`kill`), **§9** (virtiofs share),
  **§10** (sidecar provisioning + location + version lock), **§11** (Burrito/packaging — deferred),
  **§12** (validated facts), **§13** (validation-env split).
- Plan 3 spec + plan (the engine side `run` consumes): `…/specs/2026-06-24-vzbeam-plan3-run-lifecycle.md`,
  `…/plans/2026-06-24-vzbeam-run-lifecycle.md`.
- Code to match: `lib/vzbeam/sidecar.ex` (locate/version/call/stream + the `image_info`/`reid`/`restore`
  wrappers), `lib/vzbeam/commands/run.ex` (`build_argv`) + `new.ex` (restore args), and **the oracle**
  `test/support/fake_vz`. README: `README.md`.
- Prior `sbx` (reference impl; not ported line-by-line) for the Swift VZ patterns, if available.

## Carry-forwards / deferred cosmetics from Plan 3 (engine-side; fix opportunistically, not blockers)

- `run` success message em-dash renders as `\x{2014}` in escript stdout → switch to ASCII `-`
  (`lib/vzbeam/commands/run.ex`).
- `run.ex` `OptionParser.parse` silently ignores unknown flags (vs `new.ex`'s strict check) — pick one
  convention across verbs.
- `run.ex` `poll/3` forks `ps` twice per 100 ms tick (bind `alive?` once); `Sidecar.collect_stream`
  drops a `>1 MiB` line tail (unreachable for NDJSON). All Minor.

## Start by

Reading the design spec (§3/§4/§10/§12/§13), `test/support/fake_vz`, `lib/vzbeam/sidecar.ex`, and
`run.ex`'s `build_argv` — then invoking the `brainstorming` skill and working with me: (1) **confirm
which machine you're on** (build host vs M-series Mac) and scope the green-bucket-here vs HW-gated split;
(2) **settle the two `run` argv seams** (identity inputs; `--bundle` vs `--disk`/`--aux`); (3) shape the
Swift project + the provisioning/codesign task; (4) decide the manual integration-test plan for the
boot-dependent parts. Then propose a spec, then a plan. Keep it minimal; **confirm with me before
writing product code.**
