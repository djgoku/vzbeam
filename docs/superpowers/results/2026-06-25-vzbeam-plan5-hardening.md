# vzbeam Plan 5 — hardening / follow-ups: results

- **Date:** 2026-06-25
- **Branch:** `vzbeam-plan5-hardening` (off `main` `b07e832`)
- **Scope:** debt-paydown from the Plan-4 reviews / SDD ledger. Triaged with the user against the
  actual code (validate-don't-assume) before any change. All items are green-bucket — validated on
  this build host; nothing here is boot-dependent.

## Done (4 items, per-task TDD commits)

| item | commit | what |
|---|---|---|
| **C8** | `3d32e29` | `run` rejected unknown flags. It parsed with `strict:` but discarded `invalid`, so a typo'd flag was silently dropped and the VM booted with defaults. Now checks `invalid != []` → exit 2, matching `new`. |
| **A3** | `845abf6` | `run` located the sidecar twice (`Sidecar.locate/0` then `check_version/0`, which located again). Extracted `call_at/4`; `check_version` now takes the path; `run` version-checks the binary it already resolved. |
| **A1** | `dbd39f0` | A streamed `restore` could falsely succeed on a corrupt NDJSON stream — `collect_stream` silently dropped malformed/`:noeol` lines, so a stray terminal event still read as `{:ok}`. Now threads a `corrupt?` flag; `resolve/5` returns `{:protocol, :corrupt_stream}` with precedence: explicit `error` > non-zero exit > corrupt > terminal > no-terminal. Aligns the streamed path with the already-strict captured `Protocol.collect/3`. |
| **C6** | `c2f3db9` | Removed an unused `import Foundation` from `Args.swift` (uses only stdlib). |

## Verification

- `mix test` → **109 passed** (104 baseline + 5 new). `mix escript.build` → clean.
- `swift build -c release` → clean. `swift run vzcheck` → **13/13 ALL CHECKS PASS**.
- escript smoke (C8): `run dev --bogus` → `run: unknown option` (exit 2); `run ghost --gui` → known flag
  accepted, proceeds to `no such bundle` (exit 1); `run` → usage (exit 2).
- **Codex whole-branch review** (independent, git-only reads): **NOTHING BLOCKS MERGE; no should-fix
  items.** Confirmed A1 precedence (no `{:ok}` on a corrupt-with-terminal stream; no false-positive on a
  valid stream), `call_at/4` behavior-equivalence, no stale `check_version` callers, C8/`new` parity, C6 safety.

## Validate-don't-assume corrections (the backlog was wrong on three points)

- **C6 "compiler warning" — false.** The release build emits **no** warning for the unused import on this
  toolchain (Swift 6.x). The import was genuinely dead, so removal is correct hygiene, but it silenced nothing.
- **C7 "`poll/3` forks `ps` twice per tick" — false; left as-is.** Short-circuit + `cond` ordering already
  evaluate `alive?/1` **at most once** per tick, and **zero** times on the `error`/`guest_stopped` fast-paths.
  Eager "bind once" would *add* a fork to those fast-paths; any restructure still references `alive?` twice
  textually. The current code is already optimal — **C7 not done**, by design.
- **A1 "partial final line" is undetectable, not merely skipped.** Erlang's `{:line, L}` port **drops** a
  trailing unterminated line at EOF with *no* message (verified by probe). `:noeol` fires only for an
  oversize (>1 MiB) line fragment. So the detectable streamed corruptions are (a) a malformed complete line
  and (b) an oversize line; a truncated final line surfaces instead as a missing terminal / non-zero exit.
  The A1 tests exercise (a) and (b); the test for the truncated-final-line case was corrected accordingly.

## Deliberately deferred (re-confirmed, left as-is)

- **A2 graceful `stop` / `guestDidStop` HW validation** — out of scope this pass. A release-macOS Apple
  Silicon Mac is available, so this can be picked up later: add the guest NOPASSWD `/sbin/shutdown` rule,
  run `vzbeam stop <name>`, confirm `guestDidStop` → exactly one `guest_stopped` → exit 0.
- **B4 SIGTERM race** (`Run.swift installSignalTrap`) — fail-safe (SIG_IGN-first; engine escalates
  SIGTERM→SIGKILL; `kill` never fires before `started`). Leave.
- **B5 Wire key-order vs `fake_vz`** — non-defect; `VzBeam.Protocol` decodes order-independently. Leave.
- **C9 `image-info` domain `"vz"` vs `"VZErrorDomain"`** — a *consistent* convention, not a bug: `"vz"` is
  our own usage/arg errors, `"VZErrorDomain"` is framework errors (same split in `Restore.swift`). Leave.
- **C10 `Restore.swift [weak self]`** — the `[weak self]` + file-scope strong-holder is the *intentional*
  pattern (documented at `Run.swift:5`); changing it would diverge from `Run.swift`. Leave.
- **C11 `run_test.exs` `sleep 30` pid pattern** — timing-acceptable; matches existing convention. Leave.

**Conclusion:** Plan 5 closes the worth-it green-bucket debt (A3, C8, A1, C6) with TDD + an independent
clean Codex review; the rest is consciously dispositioned. MVP remains complete; nothing here is HW-gated.
