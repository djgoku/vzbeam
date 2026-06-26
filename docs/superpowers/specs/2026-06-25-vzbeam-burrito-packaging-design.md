# vzbeam — Burrito packaging (single-file distribution)

- **Date:** 2026-06-25
- **Status:** design approved (brainstorm) + Codex design-review folded in; pending final spec review
- **Builds on:** §11 "Packaging (deferred — Burrito)" of `2026-06-21-vzbeam-design.md`
- **Foundation already in place:** clean `VzBeam.CLI.main/1`; no `Mix.*` at runtime;
  sidecar found by `VzBeam.Sidecar.locate/0`, never a build path (§10 of parent). This work is
  **additive** — no redesign.

---

## 1. Goal, audience, support matrix

Produce a **single `vzbeam` executable** that runs on a fresh Apple-Silicon Mac with **no Elixir/Erlang
and no Swift toolchain** installed. One file to copy; nothing to build on the target.

Burrito (v1.5.0) wraps the Elixir engine — bundling ERTS so the host needs no BEAM — and the binary also
**carries the signed `vz` sidecar inside `priv/`**, extracted and located at runtime.

**Support matrix (explicit — Codex #5, #6):**

- **Target & build host are both Apple-Silicon macOS.** The Burrito `aarch64-darwin` target is a
  **same-arch build** (bundles the *local* ERTS), and `swift build` follows the build host's
  arch/SDK/toolchain. Building the aarch64 artifact on Intel/Linux would bundle a wrong-arch ERTS or
  sidecar — so the build host **must** be Apple Silicon. (This box satisfies it: `uname -m` = arm64,
  Swift targets `arm64-apple-macosx`.)
- **Minimum macOS = 13 (Ventura)** — the sidecar's `Package.swift` deployment floor (`.macOS(.v13)`).
  The sidecar is compiled against whatever SDK the build host carries; the floor is the runtime
  guarantee. Older macOS is out of support.

---

## 2. Scope / non-goals

**In scope**

- Add Burrito (`{:burrito, "~> 1.0"}`, Zig 0.15.2) and a `releases/0` config (one aarch64 target).
- A Burrito **patch-phase** step that builds + ad-hoc-signs `vz` into the archived payload's `priv/`.
- A release entrypoint (`Application.start/2`) that runs the CLI under Burrito and stays inert elsewhere.
- One new, **guarded** `locate/0` candidate (bundled `priv/vz`) + a defensive `chmod`.
- Docs: build/run + the quarantine note.

**Non-goals (YAGNI)**

- **Intel target.** macOS guests require Apple Silicon; `x86_64-darwin` is out.
- **Notarization / Developer ID.** Needs a paid Apple account, which contradicts the project's premise
  ("no paid Apple Developer account"). Stay ad-hoc; document the quarantine xattr instead (§8).
- **Removing the escript.** It stays for dev iteration and `mix test`.
- **Release runtime hooks** (Codex #11): no `rel/env.sh.eex`, `rel/vm.args.eex`, node name, or cookie.
  vzbeam is a one-shot, non-distributed CLI; Burrito launches the BEAM directly from its wrapper (not
  via the release shell scripts), so those hooks would be ignored anyway. Intentionally unused.
- Windows/Linux targets; auto-update; Homebrew formula.

---

## 3. The shape — one file, two separately-signed Mach-Os

This reconciles §11's "**the deliverable is two artifacts**" with single-file distribution:

- The **entitlement split is still permanent.** `vz` carries its **own** ad-hoc signature + the
  `com.apple.security.virtualization` entitlement. Burrito's Zig wrapper never signs it and never
  inherits it.
- They are simply **shipped as one file**: `vz` rides in the release `priv/`, so there are two signed
  Mach-Os physically but one thing to download.

```
vzbeam (Burrito binary)
└── <ERTS + release payload, compressed>
    └── priv/vz   ← ad-hoc-signed Mach-O, entitlement embedded in ITS signature
```

**Extraction is content-addressed (Codex #4).** First run unpacks the payload to Application Support
keyed by release **name/version/ERTS**; later runs **reuse** it and skip unpacking. Consequence: a
rebuilt sidecar at the **same version** is silently ignored unless the install is cleared — so the
deliverable build is `MIX_ENV=prod` and re-validation forces a clean install (§9). (`MIX_ENV != prod`
flips this — it *always* re-extracts — which is useful during the spike loop but is not the shipped
mode.)

---

## 4. `mix.exs` changes

- **Dep:** `{:burrito, "~> 1.0"}` (plain runtime dep — `Burrito.Util.Args` is called at runtime).
- **Keep escript, but make it app-neutral:** `escript: [main_module: VzBeam.CLI, app: nil]`.
  `app: nil` stops the escript from auto-starting the OTP app, so the new `start/2` (§5) doesn't run an
  unnecessary supervisor there — `main/1` stays the escript's only entry.
- **`application/0`:** add `mod: {VzBeam.Application, []}` (keep `extra_applications: [:logger]`).
- **`releases/0`** — staging lives in Burrito's **`extra_steps` patch phase** (the documented hook for
  injecting files into the archived payload — Codex #1), not an ad-hoc Mix step:

```elixir
def releases do
  [
    vzbeam: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [macos_silicon: [os: :darwin, cpu: :aarch64]],
        extra_steps: [patch: [post: [&VzBeam.Release.stage_sidecar/1]]]
      ]
    ]
  ]
end
```

Build the deliverable with **`MIX_ENV=prod mix release`** (Codex #3). Adding `:burrito` must not break
`mix test` or `mix escript.build` — confirmed in the spike.

---

## 5. Entrypoint — one guarded `start/2`, positive Burrito check

`VzBeam.Application.start/2` must run the CLI **only** inside a Burrito release, and stay inert under
`mix test`. Use Burrito's **documented positive signal** — `Burrito.Util.Args.get_bin_path/0` returns
`:not_in_burrito` outside a wrapped release (Codex #10 — replaces the weaker "Mix is absent" heuristic):

```elixir
def start(_type, _args) do
  if Burrito.Util.Args.get_bin_path() == :not_in_burrito do
    # dev / mix test / iex -S mix: stay inert; tests drive VzBeam.CLI.run/1 directly.
    Supervisor.start_link([], strategy: :one_for_one, name: VzBeam.Supervisor)
  else
    # Burrito-wrapped release: this IS the CLI.
    VzBeam.CLI.main(Burrito.Util.Args.argv())
    System.halt(0)  # main/1 already halts on error; halt(0) covers the success path.
  end
end
```

| Context | App started? | `get_bin_path/0` | Behavior |
|---|---|---|---|
| escript (`app: nil`) | no | — | `main/1` only |
| `mix test` / `iex -S mix` | yes | `:not_in_burrito` | inert supervisor (tests green) |
| Burrito release | yes | wrapper path | run CLI + halt |

`VzBeam.CLI.main/1` is reused unchanged: it `IO.write`s output (synchronously, so it flushes before
halt) and already `System.halt(code)`s on error. The inert branch is exercised by every `mix test` run;
**spike** confirms the release branch (CLI runs once; stdout not truncated on halt).

---

## 6. Sidecar staging — Burrito patch phase

`VzBeam.Release.stage_sidecar/1` is a **Burrito patch-phase step** — it receives and returns a
`%Burrito.Builder.Context{}`, and runs on the build Mac (Swift present). The patch phase is documented
as "where any custom files should be copied into the build directory before being archived":

1. `swift build -c release` (reuse the exact logic in `Mix.Tasks.Vz.Build` — extract a shared helper so
   the two callers don't drift).
2. `codesign --force --sign - --entitlements swift/vz.entitlements <product>` (swift drops the
   entitlement on every relink — re-sign every build, fact #10).
3. Copy signed product → the app's priv dir inside Burrito's **patch working directory**
   (`<ctx build dir>/lib/vzbeam-<vsn>/priv/vz`), `chmod 0755`. Exact context field for the build dir is
   confirmed in the spike.
4. Return the (mutated) context.

No project-level `priv/vz` artifact is produced — staging writes into the build output only. Gitignore
adds just `/burrito_out/` (Burrito's output dir); `/_build/` and `swift/.build/` are already ignored.

The existing `mix vz.build` (installs to `$VZBEAM_HOME/bin/vz`) is untouched — it's still the dev-loop
path. Staging shares its build/sign helper but targets the payload instead.

---

## 7. Sidecar location precedence

Add one candidate to `VzBeam.Sidecar.locate/0`. New order:

1. `$VZBEAM_VZ` (explicit override — always wins)
2. `$VZBEAM_HOME/bin/vz` (locally built via `mix vz.build`)
3. **bundled `priv/vz` (NEW)** — via a **guarded** priv-dir lookup
4. alongside the CLI binary
5. `vz` on `$PATH`

**Guard the priv lookup (Codex #2):** `:code.priv_dir(:vzbeam)` returns `{:error, :bad_name}` when the
app isn't loaded / has no priv dir — passing that to `Path.join/2` would **crash**. The candidate must
`case` on it and yield `nil` on `{:error, _}`, so in dev/escript (no bundled priv) it's simply absent
and **existing behavior is unchanged**.

Rationale for the order: explicit overrides still win; a dev's locally-built sidecar still beats the
bundle; on a toolchain-less Mac (#1/#2 absent) the bundle wins naturally. The `vz --version` protocol
check still guards every path.

**Selected-path observability (Codex #9, #12):** a stale `$VZBEAM_HOME/bin/vz` can shadow the bundle,
and the version check only catches *wire-protocol* drift (not entitlement/SDK/stale-behavior). So make
the resolved sidecar path observable — surface it in the not-found / version-mismatch errors (it already
carries the path) and via a `VZBEAM_DEBUG`-gated line (or equivalent) so production troubleshooting can
confirm *which* `vz` ran.

Defensive `chmod 0755` when the chosen path is the bundled `priv/vz` (in case extraction drops the exec
bit). Spike confirms whether this is actually needed.

---

## 8. Signing, quarantine, distribution channels

- **Sidecar signing:** ad-hoc only. The `com.apple.security.virtualization` entitlement is
  **non-restricted** — it works with ad-hoc signatures (no Apple approval gate). No notarization.
- **Wrapper signing (Codex #7 — decide in spike):** the spec signs `vz`, but the outer Burrito wrapper
  also needs a valid signature — Apple Silicon refuses to exec an unsigned Mach-O, and Burrito's macOS
  note calls out a Gatekeeper exemption unless signed. Open question: does Zig's link-time ad-hoc
  signature survive Burrito appending the payload, or must we `codesign --force --sign -` the wrapper
  **after** `wrap`? Spike: run the freshly wrapped binary on this box; if it won't exec or trips
  Gatekeeper, ad-hoc-sign post-wrap and re-verify.
- **Quarantine depends on channel:**
  - **scp / rsync / tar / git** *normally* set **no** `com.apple.quarantine` xattr → ad-hoc runs
    friction-free. This is the expected channel (e.g. to `dj_goku@10.5.0.48`). (Not absolute — archives
    and some transfers can carry xattrs; Codex #8 — so verify with `xattr -p com.apple.quarantine
    ./vzbeam`.)
  - **Browser download / AirDrop** set quarantine → Gatekeeper blocks an ad-hoc binary, and files the
    wrapper extracts may **inherit** quarantine (blocking the extracted `vz` too). Documented fix:
    `xattr -dr com.apple.quarantine ./vzbeam` before first run.
- **Spike checks** whether the extracted `priv/vz` inherits quarantine from a quarantined wrapper; if so,
  decide (with evidence) whether the engine should strip it from the extracted copy defensively.

---

## 9. Validation — spike-first

Per the standing constraint, this build host **cannot boot VZ guests** (no nested macOS virtualization);
boot-dependent paths validate on the **real Apple-Silicon Mac** (`dj_goku@10.5.0.48`). But almost the
entire packaging story is provable here.

**Step 1 — spike, provable on THIS box (no VM boot):**

1. `MIX_ENV=prod mix release` builds `./burrito_out/vzbeam` (Zig 0.15.2 already on PATH via `mise.toml`);
   `mix test` and `mix escript.build` still pass with `:burrito` added.
2. `vzbeam ls` / `vzbeam ip <name>` — argv plumbing through `Burrito.Util.Args.argv()` works; the
   `get_bin_path/0` guard runs the CLI (and stays inert under `mix test`).
3. stdout isn't truncated on `System.halt` (e.g. full `vzbeam --help` output).
4. **Force a clean install between iterations (Codex #4):** `vzbeam maintenance uninstall` (or bump
   version / override the install dir) before each re-test, so a stale extracted `priv/vz` can't produce
   a false positive. (`maintenance directory` / `maintenance meta` locate + describe the install.)
5. The **extracted** `priv/vz` runs: `vz --version` succeeds from the install dir (proves extraction +
   exec bit + intact binary + protocol handshake — `--version` needs no entitlement to run).
6. **Byte-identity (Codex #12):** `shasum` the staged signed product against the extracted
   `priv/vz` — must match — and confirm via `VZBEAM_DEBUG` that `vzbeam` actually *selected* the bundled
   path (Codex #9), not a shadowing `$VZBEAM_HOME/bin/vz`.
7. `codesign -d --entitlements - <extracted priv/vz>` shows the virtualization entitlement survived the
   bundle→extract round-trip.
8. **Wrapper exec + quarantine (Codex #7, #8):** the wrapped `vzbeam` runs on this box (signature OK);
   `xattr -p com.apple.quarantine ./vzbeam` is empty for the scp/local channel.
9. Cold-start: record first-run extraction time **and** steady-state per-invocation overhead of a hot
   command (`ip`) vs the escript. Expectation: steady-state comparable (both pay BEAM boot); record
   numbers, no hard SLA.

**Step 2 — HW-only (the Mac):** the single remaining unknown — a VM actually **boots** from the
extracted sidecar (`run --gui` / headless + `ssh`). Risk is low: step-1 #6 proves the extracted `vz` is
byte-identical to a known-good locally-built+signed sidecar and #7 proves the entitlement is intact.

---

## 10. Decisions record (folds into parent §11)

- Single downloadable file; entitlement split preserved (two signed Mach-Os, `vz` in `priv/`).
- aarch64-only; **Apple-Silicon build host**; min macOS 13; ad-hoc only (no notarization); escript kept.
- Staging via Burrito **patch-phase `extra_steps`**; build the deliverable with `MIX_ENV=prod`.
- Entrypoint guard via **`Burrito.Util.Args.get_bin_path/0`** (positive Burrito check); escript `app: nil`.
- `locate/0` precedence: env → `$VZBEAM_HOME/bin/vz` → **guarded** bundled `priv/vz` → alongside → PATH;
  resolved path made observable.

When this ships, update parent §11 to record that the "two artifacts" are delivered as one file.

---

## 11. Open questions / risks (resolved by the spike, not by assertion)

- Does Burrito's patch phase write into the directory that `wrap` archives, and what is the context's
  build-dir field? (Codex #1 → spike step 5/6.)
- Does the Burrito wrapper need an explicit post-`wrap` ad-hoc signature to exec / clear Gatekeeper?
  (Codex #7 → spike step 8.)
- Does Burrito preserve the `priv/vz` exec bit on extraction? (→ defensive `chmod`, §7.)
- Does a quarantined wrapper pass quarantine to extracted files? (Codex #8 → §8 doc vs defensive strip.)
- Steady-state cold-start overhead vs the escript — acceptable for hot commands? (→ spike step 9.)
