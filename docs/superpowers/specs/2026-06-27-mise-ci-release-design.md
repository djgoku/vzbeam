# mise CI + release design

**Date:** 2026-06-27
**Status:** Approved (design); pending implementation plan

## Goal

Set up CI for `vzbeam` driven by **mise tasks** (thin GitHub Actions YAML, fat mise
tasks) that:

1. **On every PR, and on pushes to `main`** — runs the test suite. (Not every branch
   push — PRs already cover branch work, and a branch-wildcard push trigger would
   double-run.)
2. **On merge to `main`** — when the `mix.exs` version is new, builds the single-file
   Burrito artifact, generates a SHA-256 checksum file, tags the commit, and publishes
   a GitHub Release with the binary + checksums so downloaders can validate the artifact.

## Context

- `vzbeam` is an Elixir CLI engine + Swift `vz` sidecar, **Apple-Silicon macOS only**.
  The engine has 159 tests.
- The release artifact is produced by `MIX_ENV=prod mix release`, which (via the
  `VzBeam.Release.StageSidecar` Burrito patch step) **builds + ad-hoc-signs the Swift
  `vz` sidecar itself** and bakes it into the payload. So the build is self-contained —
  no separate `mix vz.build` step is needed first. Output: `./burrito_out/vzbeam_macos_silicon`.
- Building requires a macOS host with the Swift toolchain + Zig 0.15.2 + xz + 7z
  (provisioned by `mise install`, pinned in `mise.lock`).
- The existing `.github/workflows/ci.yaml` calls `mise run ci` but **no `ci` task is
  defined** in the project's `mise.toml` — the current workflow is non-functional. This
  design replaces it.

## Decisions

| # | Decision |
|---|----------|
| 1 | **Runner:** everything (test + build) on a macOS Apple-Silicon runner. Spike on `macos-26`; fall back to `macos-15` (one-line `runs-on:` change) if the documented Tahoe Zig failure (`undefined symbol: _malloc_size`) bites. The **bare** labels `macos-26` / `macos-15` are arm64 (validated KB fact, 2026-06-13; `-large`/`-intel` variants are x64 — do **not** use those). A `uname -m` = `arm64` assertion runs before the build as cheap insurance against image drift, since a silent x86_64 build would yield a non-functional artifact with no error. |
| 2 | **Versioning (release trigger):** the version in `mix.exs` drives the tag `v<version>`. On merge to `main`, release only if a **complete GitHub Release** for `v<version>` does not already exist (idempotent — keyed on the release object + both assets, not bare tag existence; see control flow). Shipping = bumping `mix.exs`. |
| 3 | **Checksums:** a `SHA256SUMS` file (`<sha256>  vzbeam`), verifiable with `shasum -a 256 -c SHA256SUMS`, uploaded to the release alongside the binary. |
| 4 | **Layout:** fat mise tasks, thin YAML. All logic in `mise.toml [tasks]`; YAML checks out, sets up mise, calls tasks. **Publish gate (defense-in-depth):** the precise gate is the `release` **job-level** `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`; the mise task additionally guards the tag/publish block on `$GITHUB_ACTIONS` being non-empty (GHA-specific, narrower than `$CI`) so a local `mise run release` builds + checksums but can never publish. |
| 5 | **Published asset name:** Burrito build output stays `burrito_out/vzbeam_macos_silicon` (README + validated build path untouched). The `checksum` task copies it to `burrito_out/vzbeam`; the checksum entry and the published release asset are `vzbeam`. (Trade-off: a bare `vzbeam` name has no platform suffix — fine while the project is Apple-Silicon-macOS-only; re-add the suffix if a second target is ever added.) |

## Architecture

### mise tasks (`mise.toml [tasks]`)

| Task | Does | Local-safe |
|------|------|------------|
| `ci` | `mix deps.get` + `mix test` | yes |
| `build` | `mix deps.get` + `MIX_ENV=prod mix release` → `burrito_out/vzbeam_macos_silicon` | yes (macOS) |
| `checksum` | assert `burrito_out/vzbeam_macos_silicon` exists, `cp` it to `burrito_out/vzbeam`, then `shasum -a 256 vzbeam > SHA256SUMS` (run inside `burrito_out/` so the checksum path is relative) | yes |
| `release` | orchestrates: version/release check → `build` → `checksum` → (if in GHA) publish | build/checksum local; publish only in GHA |

**Explicit DAG** (Codex #7): `release` runs `build` → `checksum` → publish as an ordered
chain, not a parallel `depends` fan-in, because `checksum` must consume the freshly
built binary. Each step asserts its input artifact exists before proceeding:
`build` produces `vzbeam_macos_silicon`; `checksum` fails loudly if that file is
absent; publish fails loudly if `vzbeam` / `SHA256SUMS` are absent.

`build` runs `mix deps.get` itself (Codex #1): the `release` job is a fresh runner with
no workspace shared from the `test` job, and `mix release` does **not** fetch deps.

### `mise run release` control flow (idempotent)

1. `VERSION=$(mix eval 'IO.puts(Mix.Project.config()[:version])')`; `TAG=v$VERSION`.
2. **Completeness check (Codex #2 — idempotent on the *release object*, not the bare
   tag).** In GHA only: if `gh release view "$TAG"` shows a **published, non-draft**
   release that already has **both** assets (`vzbeam` and `SHA256SUMS`) → log "already
   released, skipping" and exit 0. This is the no-op path for merges that didn't bump the
   version. Gating on the release object (not tag existence) avoids the split-brain where
   a tag was pushed but the release/assets never landed — that previously skipped all
   reruns forever. **Draft handling:** this workflow never creates drafts, so a *draft*
   release at `$TAG` is an anomaly (manual/external) — **fail loudly** rather than treat
   it as "already released" or silently overwrite it.
3. Run `build` then `checksum` → produces `burrito_out/vzbeam` + `burrito_out/SHA256SUMS`.
4. **Publish — GHA only** (`$GITHUB_ACTIONS` non-empty; the job-level `if` already
   restricts this to push-to-main):
   - If the release does **not** exist: `gh release create "$TAG" --target "$GITHUB_SHA"
     --latest --notes "..." burrito_out/vzbeam burrito_out/SHA256SUMS`. `gh release
     create` **creates the tag itself** at `--target`, so there is no separate
     `git tag && git push` step and therefore no tag-without-release window. `--latest`
     is set **explicitly** (omitting it can *steal* the Latest marker — validated KB).
     If a **bare git tag** already exists for `$TAG` without a release, `gh release create`
     **adopts** that existing tag and creates the release on it (validated KB) — so this
     path self-heals an orphan tag.
   - If the release exists but is missing assets (partial prior run): recover with
     `gh release upload "$TAG" --clobber burrito_out/vzbeam burrito_out/SHA256SUMS`.
   - **Create-race (Codex):** the no-release check (step 2) and the create are not atomic,
     so two concurrent runs could both reach `create`. `gh release create` on an existing
     release **exits non-zero** (validated KB), so treat that specific failure as "lost the
     race" and fall through to the `upload --clobber` recovery rather than failing the job.
     The release-job concurrency group (below) makes this race rare; this is the belt.
   - If not in GHA (local run): stop after step 3 with "built, not publishing (not in
     GitHub Actions)".

Because `gh release create` owns tag creation, the shallow-checkout `git` tag-fetch
concern is moot for *creation*; the completeness check uses `gh release view` (the API),
not local refs. `actions/checkout` still uses `fetch-depth: 0` so `mix`/version tooling
and any future tag inspection have full history.

### GitHub Actions workflow

One workflow, two jobs, both on the macOS Apple-Silicon runner:

```yaml
on:
  pull_request:           # test only
  push:
    branches: [main]      # test, then release-if-version-is-new
  workflow_dispatch:      # manual escape hatch
```

- **`test` job** — every PR + every push to `main`. Steps: checkout (`fetch-depth: 0`) →
  setup mise (see below) → assert `uname -m == arm64` → `mise run ci`. Timeout ~15 min.
- **`release` job** — `needs: [test]` (never publishes on red) **and**
  `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` — this `if` is the
  precise publish gate. Steps: checkout (`fetch-depth: 0`) → setup mise → assert
  `uname -m == arm64` → log toolchain (`xcrun swift --version`, `xcode-select -p`) →
  `mise run release`. Timeout ~30 min. `permissions: contents: write`;
  `env: GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`.

**`workflow_dispatch` behavior** (Codex #8): a manual dispatch runs the `test` job only;
the `release` job is skipped because its `if` requires `event_name == 'push'`. (If we
later want manual releases, widen that `if` deliberately.)

### Toolchain setup — mise-action + `--locked` (spike-validated 2026-06-27)

`jdx/mise-action@v4` **auto-adds `--locked`** when a `mise.lock` is present. An older KB
fact warned that `--locked` was unusable with the source-compiled `core:erlang` backend
(no lockfile URL → abort). **That no longer applies to this project** — verified by a
local non-mutating spike (fresh `MISE_DATA_DIR`, mise 2026.6.11, macos-arm64):

```
mise install --locked --dry-run   # all 5 tools "would install", exit 0
# erlang@29.0.1, elixir@1.20.0-otp-29, zig@0.15.2, conda:7zip, conda:xz-tools
```

`mise.lock` now carries **precompiled `macos-arm64` URLs** for every tool —
`core:erlang` via `precompiled = "if_available"` → `erlef/otp_builds`, `elixir` via
`builds.hex.pm`, `zig` via `ziglang.org`, the two conda tools via `conda-forge`. With a
URL present for the build platform, `--locked` resolves cleanly.

**Therefore:** a plain `jdx/mise-action` step (letting it add `--locked`) is fine — and
`--locked` is *desirable* here, since it enforces a platform-complete lock and fully
reproducible installs from pinned URLs.

```yaml
- uses: jdx/mise-action@<pinned>
  with:
    version: <pinned-mise-version>   # pin: a recent mise release (2026.6.7) shipped no macOS build
```

Do **not** set `MISE_LOCKFILE` (KB: causes a CI post-step hang). Pin the action tag +
mise `version:` for reproducibility.

**Scope of the spike evidence:** the dry-run proves `--locked` **resolution** (every tool
has a `macos-arm64` URL in the lock), which is exactly the check that used to abort — but
it is **preliminary**, not proof of a working install. Real confirmation (download +
install + build) is deferred to the CI test job (see Validation). The evidence is also
**platform-scoped** to `macos-arm64`; that's correct for an Apple-Silicon-only project.

**Residual risk / fallback:** `--locked` requires a URL for the build platform for **every**
tool, not just erlang. It works today because all five carry `macos-arm64` URLs
(erlang/elixir precompiled for OTP-29; `zig` from ziglang.org; the two conda tools from
conda-forge). Any future version bump that lands on a tool version with **no** `macos-arm64`
artifact — an OTP/Elixir combo without a precompiled macOS build (reverts `core:erlang` to
from-source, no URL), **or** a Zig/conda version missing that platform — would make
`--locked` abort. Remedy at that point: `install: false` on mise-action + a separate plain
`- run: mise install` step. The CI test job is what surfaces this.

**Xcode/Swift pinning** (Codex #6 — deliberate staged deferral): Swift comes from the
mutable runner image and differs between `macos-26` and `macos-15`. For the spike we
**log** `xcrun swift --version` + `xcode-select -p` (drift visible in CI logs) but do
**not** pin yet — pinning a version before we know each runner's default is guesswork.
**Decision rule:** once the spike shows the default Xcode/Swift on the chosen runner,
pin it with `maxim-lobanov/setup-xcode` so the ad-hoc-sign + Burrito build is
reproducible. This is a known follow-up, not an open gap.

**Concurrency:** PR/test runs use `group: test-${{ github.ref }}` with
`cancel-in-progress: true` (kill superseded test runs). The `release` job uses a
**separate, non-cancellable** group `group: release-${{ github.ref }}` with
`cancel-in-progress: false` so a publish is never interrupted mid-flight and concurrent
main pushes serialize through the publish rather than racing on `gh release create`
(the create-race fallback in step 4 is the second line of defense).

## Safety / error handling

- **Two-layer publish gate:** job-level `if: event == 'push' && ref == 'refs/heads/main'`
  (precise) + `$GITHUB_ACTIONS` guard inside the task (local-accident belt). A local
  `mise run release` builds + checksums but never publishes.
- `release` `needs: [test]` — no publish on a red suite.
- **Idempotent on the release object** — the completeness check (`gh release view "$TAG"`
  with both assets present) makes a re-run, a no-bump merge, or recovery from a partial
  prior run all safe. `gh release create` owns tag creation, so there is no
  tag-without-release split-brain; a partial run is repaired via `gh release upload
  --clobber`.
- **arm64 assertion** before build — a silent x86_64 build can't slip through.
- `mise.lock` pins all tools so the toolchain is reproducible; install runs **with**
  `--locked` (spike-validated 2026-06-27 — erlang/elixir/zig all carry precompiled
  macos-arm64 URLs, so `--locked` resolves cleanly). `MISE_LOCKFILE` left unset
  (CI post-step hang).
- macos-26 Zig failure surfaces as a `release`-job build failure; remediation is the
  one-line `runs-on: macos-15` fallback.

## Validation (spike-first)

`mise install --locked` resolution was already validated locally (see Toolchain setup).
Land the workflow + tasks, then:
1. Confirm the `test` job runs green on a PR — this exercises `mise install --locked` on
   the real runner, confirming the precompiled erlang/elixir/zig tarballs actually
   **download + install** (not just resolve) on `macos-26`/`macos-15`.
2. Do a throwaway version bump + merge to `main`; watch whether `macos-26` builds the
   artifact or forces the `macos-15` fallback. Confirm the release is created with
   `vzbeam` + `SHA256SUMS`, and that `shasum -a 256 -c SHA256SUMS` validates the asset.

## Out of scope (YAGNI)

- Dependency / `_build` caching.
- Multi-target build matrix.
- Notarization / stapling (ad-hoc sign only, as today).
- GPG-signing the checksums file.
- Running tests on Linux (decided: macOS-only runner).
