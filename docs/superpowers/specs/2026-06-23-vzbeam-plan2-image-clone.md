# vzbeam — Plan 2 Design: image + clone (`fetch` / `images` / `new` / `rm`)

- **Status:** Draft for review (Codex pass folded in — findings #1–#8, 2026-06-23)
- **Date:** 2026-06-23
- **Scope:** Implementation-level design for Plan 2. Fills the *module-level* gaps the MVP design
  spec (`2026-06-21-vzbeam-design.md`) leaves open in §4/§5/§7. Behavior is governed by that spec;
  this doc settles module shapes, the subprocess transport, the cache layout, and the test seams.
- **Premise:** the Swift `vz` sidecar does not exist yet (Plan 4). Plan 2 builds the Elixir
  orchestration against the JSON-lines wire protocol and a **fake `vz`**; the `cp -Rc` clone and the
  IPSW cache are **real and tested here**. See §13 of the MVP spec for the green-bucket / HW split.

---

## 1. Scope

**Verbs** (added to `VzBeam.CLI.run/1` + `@usage`): `fetch <latest|PATH>`, `images`,
`new <name> <base>` (clone), `new <name> --image <latest|PATH>` (restore), `rm <name>`. (`rm --force`
— stop-then-delete — is deferred to Plan 3 with `stop`; see §6/§8, finding #4.)

**New modules:** `VzBeam.Protocol` (JSON-lines decoder), `VzBeam.Sidecar` (locate + version + invoke),
`VzBeam.Cache` (IPSW store + index), `VzBeam.AtomicFile` (extracted shared atomic write), and the
verb modules under `VzBeam.Commands.{Fetch,Images,New,Rm}`.

**Cleanups folded in first** (they touch the modules Plan 2 edits): extract `AtomicFile`; dedup the
lease reader; broaden `Ls` numeric rendering; normalize `Pidfile.write/2` errors; reconcile the
`vm.pid` `pid` type; filter `*.pending` from bundle enumeration (finding #3). See §7.

**Faked now, validated on bare-metal Apple Silicon later (§13 of MVP spec):** the real
`image-info`/`restore`/`reid` (Swift), `fetch latest`'s Apple catalog + multi-GB download, and
`run`/boot. A green `mix test` proves the orchestration, not the hypervisor.

---

## 2. Evidence from spikes (this design is grounded in these, not assumed)

Run on this host (macOS 26.5.1, Elixir 1.20.1 / OTP 29), throwaway harnesses:

- **Transport.** `System.cmd` is fully buffered — a 3-line, 1.2 s emitter returned all lines at once
  after exit; a `Port` (`{:line, N}` + `:exit_status`) streamed the same lines live (+4 / +411 /
  +818 ms). ⇒ captured `System.cmd` is fine for single-terminal calls; live progress needs a `Port`.
- **stderr.** Plain `System.cmd` cannot give clean stdout *and* a separate stderr tail: default leaves
  stderr uncaptured (leaks to console); `stderr_to_stdout: true` interleaves it *into* stdout
  (corrupts JSON-lines). A `sh -c '… 2>file'` redirect yields both. ⇒ Plan 2 reads errors from the
  JSON `{"type":"error"}` event + exit status; the stderr tail lands with Plan 3's `run.log` redirect.
- **Missing binary.** `System.cmd` on a non-existent path **raises** `ErlangError` (not `{out,
  status}`). ⇒ `Sidecar.locate/0` must existence-check and return a typed error.
- **Clone.** `cp -Rc` of a bundle preserved `disk.img` sparseness (2 GB logical / 16 K physical, same
  in the clone), cloned all files (exit 0), survived deletion of the base (clone intact, identity
  readable), and **nests when the destination already exists** (`cp -Rc dev existing/` → `existing/dev`)
  — so the clone target must always be a fresh, non-existing `.pending` path.
- **Cache copy.** `cp -c` (clonefile) of 300 MB of real data = 0.00 s vs a real `cp` = 0.46 s ⇒
  ingesting a local IPSW into the cache is ~free on the same APFS volume.
- **Native subprocess libs (erlexec / muontrap) evaluated.** Added erlexec to a throwaway escript: it
  compiled fine but **failed to start out of the box** ("No exec-port files found … Cannot find file")
  because its `priv/` port binary isn't on a real filesystem path (works under `mix run`). This is
  **surmountable**: `:exec.start(portexe: "/path/to/exec-port")` points erlexec at an externally
  provisioned binary ([ElixirForum #21603]) — i.e. ship `exec-port` exactly the way we already ship the
  `vz` sidecar (`$VZBEAM_HOME/bin/…`, located at runtime). So the escript is **not** a hard wall. The
  decision rests on need, not feasibility: (a) Plan 2's three calls are short / captured /
  single-terminal and use *none* of erlexec's features — zero-dep `Port`/`System.cmd` cover them
  (spiked); (b) erlexec's child-cleanup model is the *opposite* of `run`'s detach-survival, so it fits
  poorly the one lifecycle (Plan 3 `run`) where a process library would otherwise shine; (c) it doubles
  the native-artifact provisioning surface. muontrap additionally has the wrong semantics (kills the
  child on owner exit) and is Linux-cgroup oriented. ⇒ **zero-dep transport for Plan 2**; erlexec is a
  deliberate revisit for Plan 3's run/kill lifecycle (near-free once Burrito extracts `priv/` to disk).

  [ElixirForum #21603]: https://elixirforum.com/t/unable-to-run-erlexec-in-a-escript/21603

---

## 3. `VzBeam.Protocol` — pure JSON-lines decoder

No I/O. Exhaustively unit-tested on string fixtures.

```
@max_line 1_048_576  # 1 MiB

decode_line(binary) :: {:event, type :: String.t(), map}
                     | {:error, :bad_json | :missing_type | :oversize}

collect(lines :: [binary], terminal_types :: [String.t()], final_newline? :: boolean)
  :: {:ok, events :: [tuple], terminal :: {String.t(), map}}
   | {:error, {:vz, domain, code, message} | :no_terminal | :unterminated | :oversize | :bad_json}
```

Rules (MVP spec §4): a line over `@max_line` → `:oversize`; a decoded object with no `"type"` →
`:missing_type`; **error precedence** — any `{"type":"error"}` event dominates and maps to
`{:error, {:vz, domain, code, message}}` even if a terminal event also appears; otherwise the first
event whose type ∈ `terminal_types` is the result; **no terminal event** (EOF before terminal) →
`{:error, :no_terminal}`; a non-empty **unterminated final line** (output didn't end in `\n`, i.e.
`final_newline? == false` with a trailing partial) → `{:error, :unterminated}` (truncation guard,
master §4, finding #6); unknown `type` values are retained in `events` but never satisfy a terminal
(forward-compatible).

`collect/3` operates on a decoded **list** (captured output, split on `\n`) plus the
`final_newline?` flag the caller preserves. The same `decode_line/1` will later feed a `Port`-driven
streaming collector in Plan 3 — the decoder is transport-agnostic.

---

## 4. `VzBeam.Sidecar` — discovery + version + invocation

```
locate() :: {:ok, path} | {:error, :not_found}
check_version(path, runner \\ &System.cmd/3) :: :ok | {:error, {:incompatible, got, want} | term}
call(subcommand, args, runner \\ &System.cmd/3) :: {:ok, [event]} | {:error, term}
image_info(spec, deps) / restore(opts, deps) / reid(deps)   # thin verb wrappers
```

**`locate/0` order** (reconciles MVP spec §5 vs §10 — see §9): `VZBEAM_VZ` env → `$VZBEAM_HOME/bin/vz`
→ alongside the CLI (`:escript.script_name/0 |> Path.expand` then a sibling `vz`; best-effort, since
`script_name` returns the path *as invoked*) → `System.find_executable("vz")` (`$PATH`). Each
candidate is existence-checked **before** use so an invocation never raises (spike S3).

**`check_version/1`** runs `vz --version`, decodes `{"type":"version","protocol":N}`, and refuses a
sidecar whose `protocol` ≠ the engine's `@protocol_version` (typed `{:incompatible, …}`).

**`call/3`** invokes `runner.(path, [subcommand | args], …)` (default captured `System.cmd`), splits
stdout on `\n` **and notes whether the output ended in a newline**, then hands the lines + that flag
to `Protocol.collect/3` with the terminal set for that subcommand (`image-info`→`["image"]`,
`restore`→`["restored"]`, `reid`→`["reid"]`). A truncated final line surfaces as `:unterminated`
(finding #6); a non-zero exit with no `error` event maps to `{:error, {:exit, status}}`. The
**injectable `runner`** is the bulk test seam (returns canned `{output, status}`); a few integration
tests pass the real `&System.cmd/3` with `VZBEAM_VZ` pointed at a fake-`vz` script (approach A).

**Transport:** captured `System.cmd` for Plan 2's three calls (all single-terminal; restore progress
is unobservable here and only matters on real HW). Plan 3 streams `restore` progress via a `Port`;
**`run` is different** — it always detaches (own session + `run.log`) and survives the BEAM, so it is
**never** a BEAM-owned `Port` (finding #5). No external subprocess dependency — erlexec/muontrap
evaluated and deferred to a Plan-3 decision (§2).

---

## 5. `VzBeam.Cache` — IPSW store + index

Layout: `$VZBEAM_HOME/cache/ipsw/<build>.ipsw` + `index.json`. `build` is the canonical unique key.

```json
{ "schemaVersion": 1,
  "images": { "25F80": { "version": "26.5.1", "build": "25F80", "file": "25F80.ipsw",
                         "source": "latest", "url": "https://…", "bytes": 15837569024,
                         "fetchedAt": "2026-06-23T00:00:00Z" } } }
```

```
dir() / index_path() / read_index() / list() / lookup(build)
ensure(spec, deps) :: {:ok, entry} | {:error, term}
  deps = %{image_info: fn, download: fn, copy: fn}   # all injectable
```

**`ensure/2`** is the reusable heart (both `fetch` and `new --image` call it):

1. `{version, build, url, source} = deps.image_info.(spec)` — `spec` is `"latest"` or a local PATH
   (sidecar; faked in tests). `build` is validated as a **safe filename token** (non-empty, no path
   separators / `..`) before it is used as a path (finding #7).
2. **Already present?** If `lookup(build)` hits the index, return it. If the final `<build>.ipsw`
   exists on disk but is **missing from the index** — a crash between rename and index-write
   (finding #1) — reconcile it: write the index entry from the just-resolved metadata and return.
   `ensure/2` is thus idempotent and self-healing.
3. Acquire bytes into a **unique** `<build>.ipsw.<n>.pending` (so concurrent same-build fetches can't
   clobber one pending file): local PATH → `deps.copy` (default `cp -c`, spike S5); `latest`/`url` →
   `deps.download` (default `curl -fL -o`).
4. Size-sanity (non-zero; matches `Content-Length` when known) → `File.rename(pending, final)` →
   `AtomicFile` RMW of `index.json`.

**Crash-safety (finding #1, corrected).** The rename is the commit point: a crash *before* it leaves
only a discardable `.pending`; a crash *between* rename and index-write leaves a valid `<build>.ipsw`
that is simply **not yet indexed** — step 2 reconciles it on the next `ensure` for that build. The
guarantee is "never a corrupt/half image," **not** "never an un-indexed file."

**Concurrency (finding #2 — single-user MVP).** vzbeam is a one-shot, single-user CLI; the master
spec locks only `run.lock` (the 2-VM cap), not the cache. Unique pending names remove the same-build
clobber; a lost index update from two *different-build* fetches racing is recoverable via the step-2
reconciliation. A cache-level flock is **deferred** until concurrent use is a real need (YAGNI).

**Download = injectable, default `curl`** (zero new deps, handles multi-GB + CDN redirects + resume;
macOS always has it). The injection means green-bucket tests never touch the network — only the real
`curl`/catalog path is HW-gated. (`fetch latest` itself is untestable here: the Apple catalog was
unreachable last session — MVP spec §12.)

---

## 6. Verbs

**`fetch <latest|PATH>`** → validate spec → `Cache.ensure` → print `fetched 26.5.1 (25F80)` or
`already cached …`. `latest` orchestration is testable via injected `image_info`+`download`; real
`latest` is HW/network-gated.

**`images`** → `Cache.list/0` rendered as a table (`VERSION · BUILD · SIZE · SOURCE`).

**`new <name> <base>` (clone)** — the atomic flow validated by the clone spike:
1. Validate `name` (§8 reserved-name rules); `Manifest.read(base)` exists; **refuse if
   `Pidfile.running?(base)`** (fact #5 — clone only a cleanly-stopped base).
2. Clear any stale `<name>.pending` and ensure `<name>/` doesn't exist; `cp -Rc <base_dir>
   <name>.pending` (fresh target — never an existing dir, per the spike footgun).
3. `Sidecar.reid` → `{machineIdentifier, macAddress}` (wholesale replace; `hardwareModel` is inherited
   — it's tied to the OS image).
4. Build the clone manifest from the base's: set `name`, `base: <base>`, inherit `image` +
   `hardwareModel` + `cpuCount` + `memoryBytes`, **replace** `machineIdentifier` + `macAddress`, set
   `createdAt`. Write `config.json` into the `.pending` dir via `AtomicFile`.
5. `File.rename(<name>.pending, <name>)` (atomic). Any failure → `File.rm_rf(<name>.pending)`.

**`new <name> --image <latest|PATH>` (restore)** — mutually exclusive with a positional base:
1. Validate `name`; `Cache.ensure(image_spec)` (auto-fetch if uncached).
2. Create `<name>.pending/`; **Elixir creates a sparse `disk.img`** sized `disk_gb` (real file I/O,
   testable here — `:file.pwrite` at offset). `Sidecar.restore(ipsw:, disk:, aux:, disk_size:, cpu:,
   mem:)` populates `disk.img` and creates `aux.img` (VZMacAuxiliaryStorage), emitting `restored
   {machineIdentifier, hardwareModel, macAddress, version, build}`. *(Fake `vz` touches `aux.img` +
   emits the JSON; the real restore is HW-gated.)*
3. Write the base manifest (`base: null`, `image` from the cache entry, identity from `restored`,
   `cpuCount`/`memoryBytes` from resolved defaults/flags, `createdAt`) into `.pending`; rename.
4. Echo the chosen sizing at creation (MVP spec §6).

**`rm <name>`** → confirm the bundle exists; if `Pidfile.running?(name)` → **refuse** (`"<name> is
running; stop it first"`) — Plan 2 has no `stop` and must never hard-`pkill` a guest (fact #9); else
`File.rm_rf(<bundle_dir>)`. No base special-casing (CoW clones are independent — spike). `--force`
(stop-then-delete) arrives in Plan 3 with `stop` (finding #4).

---

## 7. Cleanups (done first)

- **`VzBeam.AtomicFile.write(path, body) :: :ok | {:error, term}`** — `mkdir_p` the dirname, write to
  `…tmp.<unique>`, `rename`, `rm` temp on error. `Manifest.write/2` and `Pidfile.write/2` both use it
  (removes the duplicated atomic-write; gives `Pidfile` the `mkdir_p` it lacked).
- **`Home.bundles/0` + bundle lookup ignore `*.pending`** (finding #3) — a crash mid-clone leaves
  `<name>.pending/config.json` carrying the *base's* identity; without filtering it surfaces in
  `ls`/`ip` as a phantom VM colliding on the base's MAC. Filter the suffix in enumeration and direct
  lookup; stale `.pending` dirs are cleared lazily by the next `new <name>` (step 2 above).
- **Lease reader dedup** — extract `VzBeam.Leases.read/0` (read `path/0`, `""` on error); `ip.ex` and
  `ls.ex` call it instead of each carrying a private `read_leases/0`.
- **`Ls` numeric rendering** — `mem/1` and the `cpuCount` cell accept `is_number` (float-encoded JSON
  from `Jason` decodes whole numbers as integers but be safe for any numeric).
- **`Pidfile.write/2` error normalization** — return `{:error, atom}` consistently (no raw
  `{:error, posix}` mixed with `{:error, :process_not_found}`).
- **`vm.pid` `pid` type → integer** — match MVP spec §5 (code currently stores a string). We're already
  editing `Pidfile`; Plan 3 is the first real writer, so aligning now keeps spec + code honest.

---

## 8. Decided defaults & scope seams (Codex-reviewed)

- **`rm --force` deferred to Plan 3 (finding #4).** Its only real job is stop-then-delete, which needs
  `stop` (Plan 3). Plan 2 `rm` deletes a stopped bundle and refuses a running one — and since
  `Pidfile.running?` already returns false for stale/dead pids, no `--force` is needed for cleanup.
  Deferring avoids a temporary divergence from the MVP `--force` contract.
- **Reserved-name validation on `new` only** (finding #7) — `new` creates a bundle dir, so reject names
  equal to a HOME-level entry (`cache`, `keys`, `bin`, `run.lock`), names containing a path separator,
  and `.`/`..`. `fetch` has no bundle name; its safety check is the **build-token sanity** on the cache
  filename (§5 step 1).
- **`reid` regenerates `{machineIdentifier, macAddress}` only** — `hardwareModel` stays (image-bound).

---

## 9. Reconciliations with the MVP spec

- **Sidecar discovery order** now explicitly includes `$VZBEAM_HOME/bin/vz` (MVP §5 mandates it as the
  install path; §10's order omitted it). New order in §4.
- **`restore` over `System.cmd` has no live progress** (spike S1). Acceptable for Plan 2 (fake `vz` is
  instant; real restore is HW-gated). Plan 3 streams `restore` progress via a `Port`. **`run` is
  different:** it always detaches and survives the BEAM (own session + `run.log` tailing — master §8),
  so it is **never** a BEAM-owned `Port` (finding #5).
- **stderr tail** (MVP §4 decoder rule) is **deferred to Plan 3** (the `run.log` redirect is its
  natural home). Plan 2 surfaces sidecar failures via the JSON `error` event + exit status. The
  **unterminated-line** rule (also MVP §4) *is* honored now via the `final_newline?` flag (finding #6).

---

## 10. Error handling (per surface)

| Surface | Failure | Result |
|---|---|---|
| Sidecar | not found | `{:error, :not_found}` → "build the sidecar (`vzbeam build-sidecar`)" + resolution order |
| Sidecar | version mismatch | refuse, typed `{:incompatible, got, want}` |
| Sidecar | non-zero exit / `error` event / truncated output | typed error, VZ domain/code preserved; `:unterminated` on a partial final line (§3) |
| `new` clone | base missing / running | refuse before any filesystem mutation |
| `new` | `<name>` exists / reserved name | refuse; never overwrite |
| `fetch`/`new --image` | network / catalog / size mismatch | actionable error; `.pending` cleaned up |
| `rm` | running | refuse (`--force`/`stop` arrive in Plan 3) |
| any | crash mid-clone | `<name>.pending` remains but is filtered from listings (finding #3) and cleared by the next `new` |
| any | crash mid-fetch | a `.pending` is discarded; an un-indexed `<build>.ipsw` self-heals on next `ensure` (finding #1) |

---

## 11. Testing strategy (approach A; all green-bucket unless noted)

- **`Protocol`** — string fixtures: partial/oversize/EOF-before-terminal/error-precedence/unknown-type
  /**unterminated final line** (finding #6).
- **`Sidecar`** — `locate/0` rungs (env / `$VZBEAM_HOME/bin/vz` / `$PATH`), `check_version` accept +
  refuse, `call/3` via injectable runner (incl. the truncated-output path); **a few integration tests**
  point `VZBEAM_VZ` at a real `fake_vz` script to prove discovery + `System.cmd` + decode end-to-end.
- **`Cache`** — `ensure/2` via injected `image_info`/`download` + **real `cp -c`** for local PATH;
  idempotent re-fetch; **orphan-final reconciliation** (finding #1); **build-token rejection**
  (finding #7); `.pending`→rename atomicity; index RMW preserves unknown keys.
- **`new` clone** — **real `cp -Rc`** into a tmp `$VZBEAM_HOME`: clone *mechanics* (file fidelity,
  sparseness), manifest identity replacement, `*.pending` invisibility (finding #3), running-base
  refusal, `.pending` cleanup on failure, base-deletion independence. *(Green-bucket proves clone
  mechanics + identity replacement; that a real VM **boots** from the clone is HW-gated clone fidelity
  — master §13/§15, finding #8.)*
- **`new --image`** — fake `vz restore` (touches `aux.img`, emits `restored`) + **real sparse
  `disk.img` creation**; manifest correctness; auto-fetch path.
- **`rm`** — stopped delete; running refusal (no `--force` in Plan 2).
- **Verbs end-to-end** via `CLI.run/1` against a populated tmp home (mirrors `integration_test.exs`).
- **HW-gated (documented, not run here):** real restore/run/boot, bootable clone fidelity, `fetch
  latest` over the live catalog.

---

## 12. Open questions

None blocking. **Codex review folded in (findings #1–#8, 2026-06-23):** #2's cache lock is deferred
(YAGNI — single-user CLI, recoverable via reconciliation); the rest are accepted and reflected above.
A second Codex pass on the riskiest mechanism (Sidecar/Protocol + clone atomicity) can run against the
implementation before it hardens, per the project's review conventions.
