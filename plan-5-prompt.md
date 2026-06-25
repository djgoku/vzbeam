# vzbeam — Plan 5 (hardening + follow-ups) handoff (paste into a fresh session)

You are continuing **vzbeam**, a tool that spins up throwaway **macOS** VMs on Apple Silicon built
directly on Apple's **Virtualization.framework** (no third-party runtime, no paid Apple Developer account).
It is split into a **Swift `vz` sidecar** (the only code that links VZ) and an **Elixir CLI engine**. **The
full MVP — Plans 1–4 — is implemented, reviewed, HW-validated, and merged to `main`.** This session is a
**hardening / follow-ups pass**, not a new feature: close (or consciously defer) the small debts the Plan-4
work and its reviews surfaced. **Validate, don't assume — read the code and the docs rather than taking the
backlog below on faith.**

Three memory files auto-load: `vzbeam-validation-environment`, `vzbeam-collaboration-style`,
`vzbeam-plan-progress`. **Read them first.** They carry the project's hard constraints, the user's working
style (aggressive YAGNI; evidence/spikes over assertion; minimal surface; Codex at milestones), and the full
plan history.

## What's on `main` (the MVP — done; don't re-create)

`mix test` → **104 green**; `mix escript.build` → `./vzbeam`; `mix vz.build` → builds + ad-hoc-signs the Swift
`vz` into `$VZBEAM_HOME/bin/vz`. Verbs: `ls`, `ip`, `images`, `fetch`, `new` (restore + CoW clone), `rm`,
`run` (`--gui`/`--headless`, `--share`), `stop`, `kill`, `ssh`. Swift sidecar (`swift/`, zero-dep SwiftPM:
`VzCore` lib + `vz` exe + `vzcheck` assertion runner): `--version`/`reid`/`image-info`/`restore`/`run`.
Plan-4 merge commit `b07e832` (`--no-ff`). **HW-validated on a release-macOS Apple Silicon Mac** (full boot
suite green); five HW-only bugs were found + fixed during that pass (see `vzbeam-plan-progress`).

## The validation reality (unchanged — this is the whole game)

- **This build host cannot boot VZ guests** (`kern.hv_support=0`). It compiles + ad-hoc-signs Swift, runs the
  green-bucket Swift checks (`cd swift && swift run vzcheck`), mints `reid`/`image-info`, and runs the full
  Elixir suite (`mix test`). It can **not** boot.
- **Boot-dependent work validates on a RELEASE-macOS Apple Silicon Mac** (the HW oracle). ⚠️ The Mac at
  `dj_goku@10.5.0.48` is a macOS **27.0 *seed*** and **cannot restore** (`MobileRestore 4014` — an OS-seed
  limitation, not a vzbeam bug); a *different* release-macOS Mac ran the suite green. Model: develop +
  green-bucket here → `rsync` tree to the Mac → `mise exec -- mix vz.build && mix escript.build` → run over
  SSH. Manual on the Mac: first-boot Setup Assistant (`run base --gui`: create `admin`, enable Remote Login)
  and a one-time guest NOPASSWD `/sbin/shutdown` (only for graceful `stop`). Confirm with the user which Mac
  is available before committing boot-dependent tasks.

## The hardening backlog (triage with the user — YAGNI hard; some are deliberate "leave it")

Sources: the Codex whole-branch review (`docs/superpowers/results/2026-06-24-vzbeam-plan4-mac-suite.md`),
the SDD ledger Minor roll-up, and the Plan-2/3 carry-forwards. **Confirm scope with the user before doing
any of these** — several are dispositioned non-defects kept here only so they're not silently lost.

**A. Real, worth considering:**
1. **`stream/4` malformed-line strictness** — `lib/vzbeam/sidecar.ex` (`collect_stream/3` + `resolve/4`).
   Malformed JSON lines and `:noeol` (>1 MiB) partials are silently skipped, so a corrupted `restore` stream
   could still "succeed" if a terminal event appears later. Harden: track the first decode error / partial
   final line; have `resolve/4` return a protocol error unless an explicit sidecar `"error"` event dominates.
   Add tests. **YAGNI check:** the real `vz` only emits valid NDJSON via `Wire` and lines are < 1 MiB, so
   this is defensive — decide if the strictness is worth it.
2. **Graceful `stop` / `guestDidStop` HW validation** — the one `swift/Sources/VzCore/Run.swift` lifecycle
   path not yet exercised on hardware (it was blocked by guest sudo). On the release Mac, add the guest
   NOPASSWD `/sbin/shutdown` rule (README "First boot"), run `vzbeam stop <name>`, and confirm
   `guestDidStop` → **exactly one** `guest_stopped` → `exit 0`. (`kill`'s SIGTERM→`vm.stop()`→`finishStopped`
   path is already HW-proven; this validates the *delegate* entry to the same `finishOnce`.)
3. **`run` locate-twice** — `lib/vzbeam/commands/run.ex:26-27` calls `Sidecar.locate/0` then
   `Sidecar.check_version/0` (which locates again). Validate the *already-located* path (add
   `Sidecar.check_version(path)` / `call_at(path, …)`). Tiny.

**B. Deliberately deferred (re-confirm; likely leave as-is):**
4. **SIGTERM race window** — `Run.swift` `installSignalTrap`: a SIGTERM between `signal(SIGTERM, SIG_IGN)`
   and `s.resume()` is dropped. **Fail-safe** (SIG_IGN-first; the engine escalates SIGTERM→SIGKILL; `kill`
   never fires before `started`/`vm.pid`). A `pthread_sigmask` block-then-source would close it fully — low
   value; leave unless the user wants belt-and-suspenders.
5. **Wire key-order vs `fake_vz`** — Swift uses `JSONSerialization(.sortedKeys)`; `fake_vz`'s hardcoded JSON
   differs in key *order*. **Non-defect** — `VzBeam.Protocol` (`Jason.decode`) is order-independent. Optional:
   align `fake_vz` key order, or soften the spec's "byte-for-byte" wording to "semantically matches".

**C. Cosmetic carry-forwards (cheap; do opportunistically if touching the file):**
6. `swift/Sources/VzCore/Args.swift` — unused `import Foundation` (remove; compiler warning).
7. `lib/vzbeam/commands/run.ex` `poll/3` — forks `ps` twice per 100 ms tick; bind `alive?(pid)` once.
8. `lib/vzbeam/commands/run.ex` `run/2` — `OptionParser.parse` silently ignores unknown flags, vs `new.ex`'s
   strict `invalid` check. Pick one convention across verbs (UX consistency).
9. `image-info` missing-arg uses domain `"vz"` vs `"VZErrorDomain"` for framework errors (defensible — leave).
10. `Restore.swift` `[weak self]` now redundant under the `liveRestore` strong holder (harmless).
11. `test/commands/run_test.exs` — the happy-path/argv tests reuse a `sleep 30` pid pre-written to `run.log`
    (timing-fragile; acceptable, matches existing pattern).

## How to work (project conventions — see `vzbeam-collaboration-style`)

- **Brainstorm → spec (`docs/superpowers/specs/`) → `writing-plans` → subagent-driven-development → reviews →
  `finishing-a-development-branch`.** For a hardening pass this may be lighter (a short spec or just a plan),
  but still confirm scope with the user first.
- **YAGNI hard.** This is debt-paydown — the user will want only the items that earn their keep. Triage
  before building; don't fix dispositioned non-defects without agreement.
- **Validate, don't assume.** Green-bucket items (Elixir, Swift `vzcheck`) are TDD here; boot-dependent items
  (graceful `stop`) need the release Mac. State validated-here vs HW-gated for each.
- **Use Codex** as an independent review point at the spec/risky-mechanism milestones (the companion's
  `task` mode is reliable from this box; `adversarial-review --scope branch` stalled on the read-only
  sandbox — prefer `task` with git-only reads).
- Branch off `main`; per-task commits; **merge `--no-ff` only when the user approves** (Plans 1–4 pattern;
  there is **no git remote** — merges are local).

## References

- Plan-4 spec/plan/results: `docs/superpowers/specs/2026-06-24-vzbeam-plan4-swift-sidecar.md`,
  `docs/superpowers/plans/2026-06-24-vzbeam-swift-sidecar.md`,
  `docs/superpowers/results/2026-06-24-vzbeam-plan4-mac-suite.md` (the HW run + the 5 bugs + the deferrals).
- Master design (incl. §16 deferred non-goals — `extract`/`sandbox`/`--attach`/Burrito — for *future*
  feature plans, not this hardening pass): `docs/superpowers/specs/2026-06-21-vzbeam-design.md`.
- Code: `lib/vzbeam/` (engine; esp. `sidecar.ex`, `commands/{run,stop}.ex`, `leases.ex`), `swift/Sources/`
  (`VzCore/{Wire,Args,Run,Restore,VMConfig,ImageInfo,ReID}.swift`), the wire oracle `test/support/fake_vz`,
  the green-bucket runner `swift/Sources/vzcheck/main.swift`, `lib/mix/tasks/vz.build.ex`. `README.md`.

## Start by

Reading the three memory files + the Plan-4 results doc, confirming **which Mac is available** for any
boot-dependent item, then **triaging the backlog with the user** (which items are worth doing — expect a
short list) before invoking `brainstorming`/`writing-plans`. Keep it minimal; confirm scope before writing
code.
