# vzbeam — whole-codebase cleanup pass: results

- **Date:** 2026-06-25
- **Branch:** `vzbeam-cleanup` (off `main` `b7e7899`)
- **Trigger:** end-to-end MVP working + HW-validated → a tech-debt / DRY / cleanup sweep.
- **Method:** 3 parallel Claude reviewers (engine core / commands / Swift) + 1 independent Codex review of
  the whole codebase (~1,944 LOC). Findings were verified against the code before acting (several reviewer
  claims were over-stated — see below), triaged with the user into 4 buckets, all implemented TDD-style.

## Implemented (4 buckets, per-task commits)

| bucket | commit | what |
|---|---|---|
| **1 — dead code + stale comments** | `54887bd` | Deleted `Manifest.write/2` + `@schema_version` (zero callers; `new` is the only writer), `Defaults.describe/0`, and the `image-info` stderr "which queue" probe; consolidated the bundle schema literal; pruned stale Plan-N / Codex provenance comments. |
| **2 — Swift error helper + a real fix** | `34c286a` | Added `Wire.emitError` + `Wire.errorFields`, routing Run/Restore/ImageInfo through them (collapsing ~6 hand-copied `(e as NSError)` unwraps + the manual underlying-error fold). **Fixed a real bug:** `Run.start`'s catch emitted our own `ConfigError` (bad machine-id/hardware-model/mac) as `domain:"VZErrorDomain", code:0`; it now maps to `domain:"vz", code:2`. Covered by new vzcheck assertions. |
| **3 — Elixir DRY** | `be3fd83` | Extracted `Pidfile.reap/3` (the byte-identical `reap/2` in stop+kill) and `Manifest.read_or/2` (the `read_manifest/1` triplicated in run/stop/ssh + `read_base/1` in new). Behavior-preserving; new direct unit tests. |
| **4 — small robustness** | `784a950` | Deleted `Cache.clear_stale_pending` (it swept **all** `*.pending` each fetch — a concurrent-fetch race; `acquire` already uses unique names + self-cleans). `run` now rejects `--gui --headless` together (exit 2). Unified the no-lease message across ip/stop/ssh. |

Plus `chore` (gitignore): untracked `.DS_Store` + root `prompt-*.md`/`prompt.md` scratch that an over-broad
`git add -A` had swept into the bucket commits, and extended `.gitignore`.

## Verify-don't-relay corrections (reviewers over-stated; checked against code)

- **Swift "Critical" `ConfigError` mislabel → real but Minor**, not Critical: near-unreachable (identity is
  sidecar-minted + round-tripped) and the message was still descriptive. Fixed anyway (cheap, folded into
  bucket 2).
- **"Args `pairFlags` off-by-one drops a valid `--share`" → false.** A *valid* trailing `--share tag path`
  is consumed correctly; only malformed `--share tag` (missing path) is mis-stored, which the engine never
  emits. Left as-is.
- **"`stop` should check ssh status and fail fast" → would regress the happy path.** A successful guest
  `shutdown` drops the ssh connection (non-zero status on success), so the ignore-status-rely-on-`reap`
  design is correct. Left as-is.
- **"Drop `headless` from Swift `booleanFlags`" → would break `--resolution` parsing** (an unregistered
  `--headless` would consume the next arg). It's an intentional no-op token; left registered.
- **C7 "`poll/3` double-forks `ps`" (from the prior pass) re-confirmed false; not touched.**

## Codex review (independent, git-only, after implementation)

**No blockers — safe to merge.** Confirmed: wire JSON shape unchanged; `ConfigError`→`vz`/2 correct;
`read_or`/`reap` behavior-equivalent with per-caller error atoms preserved; `clear_stale_pending` removal
safe; gui/headless guard correctly scoped; no-lease exit codes unchanged. Two should-fix items, both
handled: (1) the `.DS_Store`/scratch noise (untracked + gitignored), (2) the `Run` catch now uses
`localizedDescription` instead of `"\(error)"` — an **intentional improvement** (domain/code live in their
own wire fields; the message is the clean human description, consistent with every other error site; the
`ConfigError` message is byte-identical).

## Verification

- `mix test` → **110 passed** · `mix escript.build` clean · `swift build -c release` clean ·
  `swift run vzcheck` → **all checks pass** (incl. 7 new error-mapping assertions).
- escript smokes: `run dev --gui --headless` → `mutually exclusive` (exit 2); unknown-flag + happy paths intact.

**Conclusion:** net code reduction with one real bug fixed (`ConfigError` domain/code), no behavior
regressions, and an independent clean Codex review. No new features added — pure debt paydown.
