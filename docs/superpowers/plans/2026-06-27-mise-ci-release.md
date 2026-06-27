# mise CI + release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add mise-task-driven CI that tests on PRs + main pushes and, on a `mix.exs` version bump, builds the Burrito single-file artifact, emits `SHA256SUMS`, and publishes a GitHub Release (asset name `vzbeam`).

**Architecture:** Fat mise tasks, thin GitHub Actions YAML. `ci`/`build`/`checksum` are inline tasks in `mise.toml`; the more complex, branching `release` orchestration is a shellcheck-clean file task (`mise-tasks/release`) so it can be linted and unit-tested locally with mocks. One workflow with two jobs (`test`, `release`) on a macOS Apple-Silicon runner. Releasing is idempotent on the *release object* (not the bare tag) and gated to push-to-main.

**Tech Stack:** mise (tasks + lockfile), GitHub Actions (`jdx/mise-action`, `actions/checkout`), `gh` CLI (with built-in `--jq`), Elixir/Mix + Burrito, bash, shellcheck.

**Spec:** `docs/superpowers/specs/2026-06-27-mise-ci-release-design.md`

---

## Environment notes (read before starting)

- **Local host is macOS 26.5.1 (Tahoe).** Per the README, the Burrito Zig build fails on Tahoe (`undefined symbol: _malloc_size`). So `mise run build` / a full `mise run release` **cannot be verified locally**; those are verified by the CI spike (Task 7). The plan verifies everything else locally.
- **`shellcheck 0.10.0` is installed.** Use it on `mise-tasks/release`.
- **`actionlint`/`yamllint` are not reliably available.** Validate workflow YAML by parsing it with Python's `yaml` (always available via the project toolchain) and optionally `actionlint` if present.
- **Pre-existing staged changes belong to this effort:** `mise.toml` already adds `elixir = "1.20.0-otp-29"` + `erlang = "29"`, and `mise.lock` has the matching entries. Keep them; the toolchain commit (Task 1) naturally includes them.
- **Branch:** work happens on `mise-ci-release` (already created; the design spec commit `034d13c` is here).

## File Structure

- **Modify** `mise.toml` — add `[tasks.ci]`, `[tasks.build]`, `[tasks.checksum]` (inline). Already contains the `[tools]` entries.
- **Create** `mise-tasks/release` — bash file task: version read → completeness check → build → checksum → publish. shellcheck-clean. Local-safe (no publish unless `$GITHUB_ACTIONS`).
- **Create** `test/ci/release_test.sh` — mock-based unit test for the `release` publish/idempotency logic (no network, no real build).
- **Replace** `.github/workflows/ci.yaml` — two jobs (`test`, `release`). (Currently an untracked stub that just calls `mise run ci`; this replaces it.)

### Design decision to confirm

The spec says "all logic in `mise.toml [tasks]`." This plan keeps the three simple tasks inline there, but puts the **`release`** logic in `mise-tasks/release` (still a mise task, still `mise run release`) so the branching publish/recovery logic — the riskiest code — can be shellcheck-linted and unit-tested. If you'd rather have `release` inline in `mise.toml` too, say so before Task 4.

---

## Task 1: `ci` task + toolchain commit

**Files:**
- Modify: `mise.toml`

- [ ] **Step 1: Add the `ci` task to `mise.toml`**

Append to `mise.toml` (after the `[tools]` block):

```toml
[tasks.ci]
description = "Install deps and run the test suite"
run = """
mix deps.get
mix test
"""
```

- [ ] **Step 2: Verify the task is registered**

Run: `mise tasks | grep -E '^ci '`
Expected: a line for `ci` with its description.

- [ ] **Step 3: Run it (this is the test for this task)**

Run: `mise run ci`
Expected: deps resolve, then the suite runs and reports `0 failures` (the engine has ~159 tests). If you see compile or dependency errors unrelated to your change, stop and investigate before continuing.

- [ ] **Step 4: Commit (toolchain + ci task together)**

```bash
git add mise.toml mise.lock
git commit -m "feat(ci): add mise ci task; pin elixir/erlang toolchain in lock"
```

(`mise.toml` already had the `elixir`/`erlang` tool entries staged; this commit lands them with the `ci` task.)

---

## Task 2: `build` task

**Files:**
- Modify: `mise.toml`

- [ ] **Step 1: Add the `build` task to `mise.toml`**

Append:

```toml
[tasks.build]
description = "Build the Burrito single-file release (carries the signed vz sidecar)"
run = """
mix deps.get
MIX_ENV=prod mix release --overwrite
"""
```

`--overwrite` prevents the interactive "release already exists, overwrite?" prompt from hanging CI.

- [ ] **Step 2: Verify the task is registered**

Run: `mise tasks | grep -E '^build '`
Expected: a `build` line.

- [ ] **Step 3: Verify wiring (local, Tahoe-aware)**

Run: `mise run build`
Expected on this Tahoe host: it gets **past** `mix deps.get` and into `mix release`, then fails at the Burrito **Zig** step with the documented `undefined symbol: _malloc_size` (or a similar Zig/SDK error). That failure proves the task is wired correctly; a *successful* build is verified in CI (Task 7). If instead it fails with "task not found", a deps error, or `MIX_ENV` unset, fix the task.

> If you are NOT on Tahoe and the build succeeds, even better — confirm `burrito_out/vzbeam_macos_silicon` exists.

- [ ] **Step 4: Commit**

```bash
git add mise.toml
git commit -m "feat(ci): add mise build task (MIX_ENV=prod mix release --overwrite)"
```

---

## Task 3: `checksum` task

**Files:**
- Modify: `mise.toml`

- [ ] **Step 1: Add the `checksum` task to `mise.toml`**

Append:

```toml
[tasks.checksum]
description = "Copy the Burrito output to 'vzbeam' and write SHA256SUMS (relative paths)"
run = """
test -f burrito_out/vzbeam_macos_silicon || { echo "checksum: missing burrito_out/vzbeam_macos_silicon (run 'mise run build' first)" >&2; exit 1; }
cd burrito_out
cp vzbeam_macos_silicon vzbeam
shasum -a 256 vzbeam > SHA256SUMS
shasum -a 256 -c SHA256SUMS
"""
```

The guard runs **before** `cd burrito_out` (checking the prefixed path) — otherwise, when `burrito_out/` doesn't exist, the `cd` fails first and the custom error message never prints. Then `cd burrito_out` keeps the path in `SHA256SUMS` relative (`vzbeam`, not `burrito_out/vzbeam`) so `shasum -a 256 -c SHA256SUMS` works after a user downloads both files into one directory.

- [ ] **Step 2: Test the guard — run with no artifact (expect clean failure)**

```bash
rm -rf burrito_out
mise run checksum; echo "exit=$?"
```
Expected: prints `checksum: missing burrito_out/vzbeam_macos_silicon ...` and `exit=1` (non-zero). (mise may wrap the exit code; the key is it fails loudly, not silently.)

- [ ] **Step 3: Test the happy path with a stub artifact**

```bash
mkdir -p burrito_out
printf 'dummy-binary-bytes\n' > burrito_out/vzbeam_macos_silicon
mise run checksum
echo "--- produced files ---"; ls -1 burrito_out
echo "--- SHA256SUMS ---"; cat burrito_out/SHA256SUMS
```
Expected: `mise run checksum` ends with `vzbeam: OK`; `burrito_out/` contains `vzbeam` and `SHA256SUMS`; `SHA256SUMS` is one line of the form `<64-hex>  vzbeam`.

- [ ] **Step 4: Clean up the stub and commit**

```bash
rm -rf burrito_out
git add mise.toml
git commit -m "feat(ci): add mise checksum task (vzbeam + SHA256SUMS, relative)"
```

---

## Task 4: `release` task (script) + unit test

> **POST-REVIEW HARDENING (supersedes the script/test code blocks below).** A final
> adversarial review flagged two HIGH issues in the release-object-keyed design originally
> shown here: (1) a *deleted* release could be recreated from a newer commit, and (2) a
> transient asset-query error could be misread as "partial" and trigger a destructive
> `gh release upload --clobber`. The release task was therefore redesigned to be
> **tag-keyed and fail-closed** (idempotency keyed on the immutable git tag `v<version>`;
> uncertain/partial/deleted/draft/API-error states **abort** for a human; `--clobber`
> removed entirely). The authoritative design is the **"`mise run release` control flow
> (tag-keyed, fail-closed)"** section of the spec, and the implementations are the committed
> `mise-tasks/release` + `test/ci/release_test.sh` (the test grew to 11 scenarios / 41
> assertions). The code blocks below are retained as the original design record.

**Files:**
- Create: `test/ci/release_test.sh`
- Create: `mise-tasks/release`

- [ ] **Step 1: Write the failing test**

Create `test/ci/release_test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for mise-tasks/release publish/idempotency logic.
# PATH-injected mocks for mix/mise/gh — no network, no real build.
# Run: bash test/ci/release_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE="${ROOT}/mise-tasks/release"
PASS=0
FAIL=0

make_mocks() { # $1 = mock dir
  local d="$1"
  mkdir -p "$d"
  cat >"$d/mix" <<'EOF'
#!/usr/bin/env bash
# only invoked as: mix eval 'IO.puts(Mix.Project.config()[:version])'
echo "0.1.0"
EOF
  cat >"$d/mise" <<'EOF'
#!/usr/bin/env bash
# emulate 'mise run build' and 'mise run checksum' by creating dummy artifacts
if [ "${1:-}" = "run" ] && [ "${2:-}" = "build" ]; then
  mkdir -p burrito_out; printf 'dummy\n' > burrito_out/vzbeam_macos_silicon
elif [ "${1:-}" = "run" ] && [ "${2:-}" = "checksum" ]; then
  mkdir -p burrito_out
  cp burrito_out/vzbeam_macos_silicon burrito_out/vzbeam
  ( cd burrito_out && shasum -a 256 vzbeam > SHA256SUMS )
fi
EOF
  cat >"$d/gh" <<'EOF'
#!/usr/bin/env bash
# behavior driven by $FAKE_STATE; appends every call to $GH_LOG
echo "gh $*" >> "$GH_LOG"
action="${2:-}"
case "${FAKE_STATE}" in
  absent)   [ "$action" = "view" ] && exit 1; exit 0 ;;
  partial)
    if [ "$action" = "view" ]; then
      case "$*" in *isDraft*) echo "false"; exit 0 ;; *assets*) echo "vzbeam"; exit 0 ;; esac
    fi
    exit 0 ;;
  complete)
    if [ "$action" = "view" ]; then
      case "$*" in *isDraft*) echo "false"; exit 0 ;; *assets*) printf 'vzbeam\nSHA256SUMS\n'; exit 0 ;; esac
    fi
    exit 0 ;;
  draft)
    if [ "$action" = "view" ]; then case "$*" in *isDraft*) echo "true"; exit 0 ;; esac; fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/mix" "$d/mise" "$d/gh"
}

# run_case NAME FAKE_STATE CI(0/1) -> sets globals: RC, OUT, LOG, CWD
run_case() {
  local name="$1" state="$2" ci="$3"
  local work mock
  work="$(mktemp -d)"
  mock="${work}/bin"
  make_mocks "$mock"
  export GH_LOG="${work}/gh.log"; : > "$GH_LOG"
  export FAKE_STATE="$state"
  export GITHUB_SHA="deadbeef"
  if [ "$ci" = "1" ]; then export GITHUB_ACTIONS="true"; else unset GITHUB_ACTIONS; fi
  OUT="$(cd "$work" && PATH="${mock}:${PATH}" bash "$RELEASE" 2>&1)"; RC=$?
  LOG="$(cat "$GH_LOG")"
  CWD="$work"
  CASE="$name"
}

ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf 'FAIL - %s\n     %s\n' "$1" "$2"; }
assert_rc()        { [ "$RC" = "$1" ] && ok "$CASE: rc=$1" || no "$CASE: rc" "want $1 got $RC; out: $OUT"; }
assert_log_has()   { grep -q "$1" <<<"$LOG"  && ok "$CASE: log has '$1'"  || no "$CASE: log has '$1'"  "log: $LOG"; }
assert_log_lacks() { grep -q "$1" <<<"$LOG"  && no "$CASE: log lacks '$1'" "log: $LOG" || ok "$CASE: log lacks '$1'"; }
assert_out_has()   { grep -q "$1" <<<"$OUT"  && ok "$CASE: out has '$1'"  || no "$CASE: out has '$1'"  "out: $OUT"; }

# local: builds + checksums, never publishes
run_case "local-no-publish" absent 0
assert_rc 0; assert_out_has "not publishing"; assert_log_lacks "release create"; assert_log_lacks "release upload"

# CI absent: creates the release
run_case "ci-absent-create" absent 1
assert_rc 0; assert_log_has "release create"

# CI partial: recovers via upload --clobber
run_case "ci-partial-upload" partial 1
assert_rc 0; assert_log_has "release upload"

# CI complete: skips before building or publishing
run_case "ci-complete-skip" complete 1
assert_rc 0; assert_out_has "already published"; assert_log_lacks "release create"; assert_log_lacks "release upload"
[ -f "${CWD}/burrito_out/vzbeam" ] && no "ci-complete-skip: must not build" "artifact created" || ok "ci-complete-skip: no build"

# CI draft: refuses
run_case "ci-draft-refuse" draft 1
assert_rc 1; assert_out_has "DRAFT"

echo "-----------------------------"
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" = "0" ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/ci/release_test.sh; echo "exit=$?"`
Expected: FAIL — the script `mise-tasks/release` does not exist yet, so every case errors (`exit=1`).

- [ ] **Step 3: Write the `release` script**

Create `mise-tasks/release`:

```bash
#!/usr/bin/env bash
# mise task: build, checksum, and (only in GitHub Actions) publish a GitHub Release.
# Idempotent on the release OBJECT (not the bare tag). Local-safe: without
# $GITHUB_ACTIONS it builds + checksums but never tags or publishes.
#MISE description="Build, checksum, and publish a GitHub Release on a version bump"
set -euo pipefail

VERSION="$(mix eval 'IO.puts(Mix.Project.config()[:version])')"
TAG="v${VERSION}"
echo "release: version=${VERSION} tag=${TAG}"

in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }

# Echoes one of: absent | draft | partial | complete
release_state() {
  local draft names
  if ! draft="$(gh release view "${TAG}" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
    echo absent; return
  fi
  if [ "${draft}" = "true" ]; then
    echo draft; return
  fi
  names="$(gh release view "${TAG}" --json assets --jq '.assets[].name' 2>/dev/null || true)"
  if grep -qx 'vzbeam' <<<"${names}" && grep -qx 'SHA256SUMS' <<<"${names}"; then
    echo complete
  else
    echo partial
  fi
}

# 1. Completeness check (CI only) — skip if already fully published.
if in_ci; then
  case "$(release_state)" in
    complete)
      echo "release: ${TAG} already published with both assets — skipping"
      exit 0 ;;
    draft)
      echo "release: ERROR ${TAG} exists as a DRAFT (anomaly, not created by this workflow) — refusing" >&2
      exit 1 ;;
    partial)
      echo "release: ${TAG} exists but assets incomplete — will recover after build" ;;
    absent)
      echo "release: no existing release for ${TAG} — will create" ;;
  esac
fi

# 2. Build + checksum (local-safe).
mise run build
mise run checksum

ASSETS=(burrito_out/vzbeam burrito_out/SHA256SUMS)

# 3. Publish (CI only).
if ! in_ci; then
  echo "release: built + checksummed; not in GitHub Actions — not publishing"
  exit 0
fi

case "$(release_state)" in
  complete)
    echo "release: ${TAG} became complete concurrently — nothing to upload" ;;
  partial)
    echo "release: uploading assets to existing ${TAG} (recovery)"
    gh release upload "${TAG}" --clobber "${ASSETS[@]}" ;;
  absent)
    echo "release: creating ${TAG}"
    if ! gh release create "${TAG}" --target "${GITHUB_SHA}" --latest \
          --title "${TAG}" --notes "Automated release ${TAG}" "${ASSETS[@]}"; then
      echo "release: create failed (lost create-race?) — recovering via upload"
      gh release upload "${TAG}" --clobber "${ASSETS[@]}"
    fi ;;
  draft)
    echo "release: ERROR ${TAG} is a draft — refusing" >&2
    exit 1 ;;
esac
echo "release: done ${TAG}"
```

- [ ] **Step 4: Make it executable and confirm mise discovers it**

```bash
chmod +x mise-tasks/release
mise tasks | grep -E '^release '
```
Expected: a `release` task line (mise auto-discovers executables in `mise-tasks/`). If it does not appear, confirm the file is executable and has the `#!/usr/bin/env bash` shebang.

- [ ] **Step 5: Lint the script**

Run: `shellcheck mise-tasks/release`
Expected: no output (clean). Fix any warnings.

- [ ] **Step 6: Run the unit test to verify it passes**

Run: `bash test/ci/release_test.sh; echo "exit=$?"`
Expected: all cases `ok`, final line `PASS=N FAIL=0`, `exit=0`.

- [ ] **Step 7: Commit**

```bash
git add mise-tasks/release test/ci/release_test.sh
git commit -m "feat(ci): add mise release task (idempotent gh release) + unit test"
```

---

## Task 5: GitHub Actions workflow

**Files:**
- Replace: `.github/workflows/ci.yaml`

- [ ] **Step 1: Replace the workflow file**

Overwrite `.github/workflows/ci.yaml` with:

```yaml
name: ci

on:
  workflow_dispatch:
  pull_request:
  push:
    branches: ["main"]

jobs:
  test:
    runs-on: macos-26
    timeout-minutes: 15
    concurrency:
      group: test-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: jdx/mise-action@v4
        with:
          version: 2026.6.11
      - name: Assert Apple Silicon
        run: |
          arch="$(uname -m)"
          echo "runner arch: ${arch}"
          test "${arch}" = "arm64"
      - run: mise run ci

  release:
    needs: [test]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: macos-26
    timeout-minutes: 30
    permissions:
      contents: write
    concurrency:
      group: release-${{ github.ref }}
      cancel-in-progress: false
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: jdx/mise-action@v4
        with:
          version: 2026.6.11
      - name: Assert Apple Silicon
        run: |
          arch="$(uname -m)"
          echo "runner arch: ${arch}"
          test "${arch}" = "arm64"
      - name: Log toolchain (Xcode/Swift)
        run: |
          xcode-select -p
          xcrun swift --version
      - run: mise run release
```

> **macos-15 fallback:** if the macos-26 spike hits the Tahoe Zig failure, change both `runs-on: macos-26` to `runs-on: macos-15`. That is the only change needed.

- [ ] **Step 2: Validate the YAML parses**

Run:
```bash
mise exec -- elixir -e ':ok' >/dev/null 2>&1 # ensure toolchain; ignore
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yaml')); print('yaml ok')"
```
Expected: `yaml ok` (no traceback). If `python3` is unavailable, run `actionlint .github/workflows/ci.yaml` instead (install with `mise x actionlint -- actionlint ...` or skip and rely on the spike).

- [ ] **Step 3: Sanity-check the structure**

Run:
```bash
grep -nE 'runs-on:|if:|group:|cancel-in-progress:|mise run' .github/workflows/ci.yaml
```
Expected: two `runs-on: macos-26`; the release `if:` line with `github.event_name == 'push' && github.ref == 'refs/heads/main'`; `test-` and `release-` concurrency groups; `mise run ci` and `mise run release`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "feat(ci): two-job macOS workflow (test on PR/main; release on version bump)"
```

---

## Task 6: Local end-to-end sanity (everything except build/publish)

**Files:** none (verification only)

- [ ] **Step 1: All four tasks are registered**

Run: `mise tasks | grep -E '^(ci|build|checksum|release) '`
Expected: four lines.

- [ ] **Step 2: Re-run the suite via the task**

Run: `mise run ci`
Expected: `0 failures`.

- [ ] **Step 3: Re-run the release unit test**

Run: `bash test/ci/release_test.sh`
Expected: `PASS=N FAIL=0`.

- [ ] **Step 4: shellcheck stays clean**

Run: `shellcheck mise-tasks/release`
Expected: no output.

No commit (verification only).

---

## Task 7: CI spike validation (manual, requires pushing)

**Files:** none (this is the spike from the spec's Validation section)

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin mise-ci-release
gh pr create --fill --base main
```

- [ ] **Step 2: Watch the `test` job**

Run: `gh run watch` (or `gh run list --branch mise-ci-release`)
Expected: the `test` job is **green** — this is the real confirmation that `mise install --locked` actually downloads + installs the precompiled erlang/elixir/zig on `macos-26`, and that `mix test` passes there. The `release` job should be **skipped** on the PR (not a push to main).

- [ ] **Step 3: If `test` fails at toolchain install** (`--locked`/precompiled issue)

Apply the documented fallback in `.github/workflows/ci.yaml`: replace the `jdx/mise-action@v4` step with
```yaml
      - uses: jdx/mise-action@v4
        with:
          version: 2026.6.11
          install: false
      - run: mise install
```
in both jobs, commit, push, re-check. (See spec "Residual risk / fallback".)

- [ ] **Step 4: If `test` fails because `macos-26` can't build/queue**

Switch both `runs-on: macos-26` → `runs-on: macos-15`, commit, push, re-check.

- [ ] **Step 5: Merge and validate the release path**

After `test` is green and the PR is approved, merge to `main`. Because `mix.exs` is still `0.1.0`, the **first** merge will either create release `v0.1.0` (if none exists) or — on later no-bump merges — skip. To exercise a real release, bump `mix.exs` version (e.g. to `0.1.1`) in a follow-up PR.
Expected after a version-bump merge: the `release` job builds the artifact (or forces the macos-15 fallback), and a GitHub Release `v<version>` appears with assets `vzbeam` + `SHA256SUMS`.

- [ ] **Step 6: Verify the published checksum**

```bash
gh release download "v<version>" --pattern 'vzbeam' --pattern 'SHA256SUMS' --dir /tmp/relcheck
( cd /tmp/relcheck && shasum -a 256 -c SHA256SUMS )
```
Expected: `vzbeam: OK`.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Test on PR + main push → Task 5 `test` job + Task 1 `ci` task. ✓
- Build Burrito artifact on version bump → Task 2 `build`, Task 4 `release`, Task 5 `release` job. ✓
- SHA256SUMS → Task 3 `checksum`. ✓
- Publish GitHub Release, asset `vzbeam` → Task 3 (rename) + Task 4 (publish). ✓
- Versioning from `mix.exs`, idempotent on release object → Task 4 `release_state` + completeness check. ✓
- Publish gate (job `if` + `$GITHUB_ACTIONS`) → Task 4 (`in_ci`) + Task 5 (`if:`). ✓
- arm64 assertion → Task 5. ✓
- `--locked` via mise-action + version pin → Task 5 (`jdx/mise-action@v4` + `version:`). ✓
- Concurrency groups (per-job) → Task 5. ✓
- macos-26 spike + macos-15 fallback → Task 5 note + Task 7 steps 3–4. ✓
- Validation/spike → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code/step is concrete. The only `<version>` placeholders are in Task 7 manual commands where the version is chosen at runtime — intentional.

**Type/name consistency:** task names `ci`/`build`/`checksum`/`release` consistent across `mise.toml`, the script, the test, and the workflow. Asset names `vzbeam`/`SHA256SUMS` consistent across `checksum`, `release`, the test mocks, and Task 7. `release_state` values (`absent`/`draft`/`partial`/`complete`) handled in both the completeness check and the publish switch.

**Scope:** single subsystem (CI/release). No decomposition needed.
