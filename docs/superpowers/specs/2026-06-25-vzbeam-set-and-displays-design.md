# vzbeam — `set` + `displays` (VM config ergonomics): design

- **Date:** 2026-06-25
- **Status:** design approved in brainstorm; spec for review → `writing-plans`.
- **Context:** two small post-MVP ergonomics. Both are **engine-only** — no Swift sidecar change, no
  wire-protocol change.

## Goals

1. **Edit a VM's CPU/RAM after creation** without hand-editing `config.json` or computing byte counts.
2. **Help pick a guest `--resolution`** by showing the host display(s) and suggesting sensible values.

## Non-goals (deliberate, YAGNI)

- **Disk resize** — sparse-image growth + guest volume expansion is a separate, riskier job.
- **Silent auto-match of resolution** — deferred. Suggestions come first; the host-resolution detector this
  adds makes auto-default a trivial one-line follow-on if we later want it.
- Multi-display *selection*, GPU/other hardware edits, presets/named resolutions.

---

## Feature A — `vzbeam set <name> [--cpu N] [--mem-gb M]`

Edit a stopped VM's CPU count and/or memory in place, using the same friendly units as `new`.

**Behavior**
- Parse `strict: [cpu: :integer, mem_gb: :integer]`; reject `invalid != []` (exit 2) — this covers both
  unknown flags **and** bad-typed values (`--cpu nope` lands in `invalid`), matching `new`/`run`.
- Exact arity: the single `<name>` positional (extra positionals like `set dev extra` → usage, exit 2) and
  **at least one** of `--cpu` / `--mem-gb` (else usage, exit 2).
- `Manifest.read_or(name, :no_such_bundle)`; refuse a **running** VM (`Pidfile.running?`) → exit 1,
  "`set: <name> is running; stop it first`" (resource changes apply on next boot).
- Validate given values: `cpu >= 1`, `mem_gb >= 1` → else exit 2.
- Update only the given keys: `cpuCount` and/or `memoryBytes = mem_gb * 1 GiB`; preserve all other keys.
- Atomic-write `config.json`; on write failure → exit 1, `set failed: <reason>` (the verbs' catch-all error
  pattern). On success print `set <name>: cpu=<n> mem=<m>G` showing **both effective values** (a
  `--cpu`-only call still prints the current memory, and vice-versa).

**Manifest writer (shared, small refactor):** extract `Manifest.write_to(path, map)` — atomic +
schema-stamped (`@schema_version`) — and have **both** `new` (writes the `.pending` path) and `set` (writes
the live `Manifest.path(name)`) use it. (`Manifest.write/2` was removed in the cleanup pass as *dead*; `set`
now gives the writer a real second caller, so a shared writer is justified rather than premature.)

**Validation:** green-bucket (TDD on this host — temp manifest, no boot).

---

## Feature B — `vzbeam displays`

A read-only helper that prints the host display(s) and suggests `--resolution` values.

**Detection (engine-side, injectable):** a dep `profiler/0` that defaults to shelling
`system_profiler SPDisplaysDataType -json` and returns its stdout; injectable so tests run against a captured
fixture. Consistent with how the engine already shells out (`ps`, `cp`, `curl`, `ssh`).

**Parse:** decode the JSON and, per display, extract the **name** and **native pixel resolution** (plus the
scaled "looks like" points + scale factor when present, for display only). The exact JSON field path is
captured by the Mac spike (plan task 1) and frozen into a test fixture; the parser is written against that
fixture. Marking the main display is best-effort.

**Suggestions:** pick the display flagged *main*; if none is flagged, the first (the parser preserves
`system_profiler`'s input order deterministically). From its native `W×H`, offer a short deduped list —
`W×H` (match host, crispest), `(W div 2)×(H div 2)` (integer floor; smaller window), and the vzbeam default
`1920×1200`. Example:

```
$ vzbeam displays
Built-in Liquid Retina   3024 x 1964 native   (looks like 1512 x 982 @2x)
suggested --resolution:
  3024x1964   match host — crispest
  1512x982    half — smaller window
  1920x1200   vzbeam default (16:10)
```

**Errors / no display:** if `system_profiler` is absent, errors, or reports no usable display (headless /
pure-SSH host), print a clear one-liner ("`no display detected; vzbeam default is 1920x1200`") and exit 0 —
this is an informational helper, not a failure.

**`run` is unchanged** — its `--resolution` default stays `1920x1200`; `displays` only advises.

**Validation:** the parser + suggestion logic are green-bucket (TDD here against the captured fixture). The
**live** `system_profiler` call and the fixture itself are **HW-gated** — spike
`system_profiler SPDisplaysDataType -json` on the release Mac first to capture the real schema.

---

## CLI wiring

- `cli.ex`: add `set` and `displays` to dispatch + the usage/help text. Same `{:ok, iodata}` /
  `{:error, code, iodata}` contract and exit-code discipline (2 = usage/unknown-flag, 1 = runtime) as every
  other verb.

## Testing summary

- **A (here):** cpu-only / mem-only / both (each asserts *both* effective values are printed); mem-gb →
  correct byte count; preserves other manifest keys; refuses running; refuses missing bundle; usage (exit 2)
  on no-flags, bad-typed flag (`--cpu nope`), unknown flag, and extra positional; write failure → exit 1.
- **B (here):** parse the captured fixture → expected displays + suggestions; missing-name and
  missing-resolution fields → graceful skip; empty / garbage / no-display input → the fallback line.
  **(Mac):** capture the fixture; confirm the live call + parse.
- **CLI:** `cli_test` asserts `set` and `displays` dispatch and appear in help.

## Build order

1. **A — `set`** (green-bucket, ship independently of the Mac).
2. **B spike** on the Mac: capture `system_profiler SPDisplaysDataType -json` → fixture.
3. **B — `displays`** parser/suggestions/CLI (TDD against the fixture), then validate live on the Mac.
