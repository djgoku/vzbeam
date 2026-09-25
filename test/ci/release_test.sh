#!/usr/bin/env bash
# Unit tests for mise-tasks/release publish/idempotency logic.
# PATH-injected mocks for mix/mise/gh -- no network, no real build.
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
# emulate 'mise run version' ($FAKE_VERSION), and 'mise run build' and 'mise run checksum'
# by creating dummy artifacts
if [ "${1:-}" = "run" ] && [ "${2:-}" = "version" ]; then
  echo "${FAKE_VERSION}"
elif [ "${1:-}" = "run" ] && [ "${2:-}" = "build" ]; then
  mkdir -p burrito_out
  printf 'dummy\n' > burrito_out/vzbeam_macos_silicon
elif [ "${1:-}" = "run" ] && [ "${2:-}" = "checksum" ]; then
  mkdir -p burrito_out
  cp burrito_out/vzbeam_macos_silicon burrito_out/vzbeam
  ( cd burrito_out && shasum -a 256 vzbeam > SHA256SUMS )
fi
EOF
  cat >"$d/gh" <<'EOF'
#!/usr/bin/env bash
# behavior driven by $FAKE_TAG/$FAKE_REL/$FAKE_CREATE; appends every call to $GH_LOG
echo "gh $*" >> "$GH_LOG"

if [ "${1:-}" = "api" ]; then
  case "${FAKE_TAG:-absent}" in
    present) exit 0 ;;
    absent) echo "HTTP 404: Not Found" >&2; exit 1 ;;
    error) echo "HTTP 500: unavailable" >&2; exit 1 ;;
  esac
fi

if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *isDraft*)
      case "${FAKE_REL:-absent}" in
        absent) echo "release not found" >&2; exit 1 ;;
        draft) echo "true"; exit 0 ;;
        partial|nobundle|complete|assets-error) echo "false"; exit 0 ;;
        error) echo "release API error" >&2; exit 1 ;;
      esac
      ;;
    *assets*)
      case "${FAKE_REL:-absent}" in
        absent) echo "release not found" >&2; exit 1 ;;
        draft) exit 0 ;;
        partial) echo "vzbeam"; exit 0 ;;
        nobundle) printf 'vzbeam\nSHA256SUMS\n'; exit 0 ;;
        complete) printf 'vzbeam\nSHA256SUMS\npackslip.sigstore.json\n'; exit 0 ;;
        assets-error) echo "assets API error" >&2; exit 1 ;;
        error) echo "release API error" >&2; exit 1 ;;
      esac
      ;;
  esac
fi

if [ "${1:-}" = "release" ] && [ "${2:-}" = "create" ]; then
  case "${FAKE_CREATE:-ok}" in
    ok) exit 0 ;;
    fail) echo "create failed" >&2; exit 1 ;;
  esac
fi

exit 0
EOF
  cat >"$d/packslip" <<'EOF'
#!/usr/bin/env bash
# behavior driven by $FAKE_SIGN; appends every call to $GH_LOG (one log keeps the call order)
echo "packslip $*" >> "$GH_LOG"

case "${1:-}" in
  keygen) # keygen --out DIR/NAME.key -> NAME.key + NAME.pub
    : > "$3"
    : > "${3%.key}.pub"
    ;;
  create)
    [ "${FAKE_SIGN:-ok}" = "ok" ] || { echo "signing failed" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      if [ "$1" = "--out" ]; then mkdir -p "$2" && : > "$2/packslip.sigstore.json"; fi
      shift
    done
    ;;
esac

exit 0
EOF
  chmod +x "$d/mix" "$d/mise" "$d/gh" "$d/packslip"
}

# run_case NAME CI(0/1) FAKE_TAG FAKE_REL FAKE_CREATE [VERSION] [GITHUB_REF] [FAKE_SIGN]
#   -> sets globals: RC, OUT, LOG, CWD, GHOUT (the $GITHUB_OUTPUT file's contents)
run_case() {
  local name="$1"
  local ci="$2"
  local fake_tag="$3"
  local fake_rel="$4"
  local fake_create="$5"
  local work mock
  work="$(mktemp -d)"
  mock="${work}/bin"
  make_mocks "$mock"
  export GH_LOG="${work}/gh.log"
  : > "$GH_LOG"
  export GITHUB_OUTPUT="${work}/github_output"
  : > "$GITHUB_OUTPUT"
  export FAKE_TAG="$fake_tag"
  export FAKE_REL="$fake_rel"
  export FAKE_CREATE="$fake_create"
  export FAKE_VERSION="${6:-0.1.0}"
  export GITHUB_REF="${7:-refs/heads/main}"
  export FAKE_SIGN="${8:-ok}"
  unset GITHUB_REPOSITORY
  export GITHUB_SHA="deadbeef"
  if [ "$ci" = "1" ]; then
    export GITHUB_ACTIONS="true"
  else
    unset GITHUB_ACTIONS
  fi
  OUT="$(cd "$work" && PATH="${mock}:${PATH}" bash "$RELEASE" 2>&1)"
  RC=$?
  LOG="$(cat "$GH_LOG")"
  GHOUT="$(cat "$GITHUB_OUTPUT")"
  CWD="$work"
  CASE="$name"
}

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n     %s\n' "$1" "$2"; }

assert_rc() {
  if [ "$RC" = "$1" ]; then
    ok "$CASE: rc=$1"
  else
    no "$CASE: rc" "want $1 got $RC; out: $OUT"
  fi
}

assert_out_has() {
  if grep -Fq -- "$1" <<<"$OUT"; then
    ok "$CASE: out has '$1'"
  else
    no "$CASE: out has '$1'" "out: $OUT"
  fi
}

assert_log_has() {
  if grep -Fq -- "$1" <<<"$LOG"; then
    ok "$CASE: log has '$1'"
  else
    no "$CASE: log has '$1'" "log: $LOG"
  fi
}

assert_log_lacks() {
  if grep -Fq -- "$1" <<<"$LOG"; then
    no "$CASE: log lacks '$1'" "log: $LOG"
  else
    ok "$CASE: log lacks '$1'"
  fi
}

assert_ghout_has() {
  if grep -Fxq -- "$1" <<<"$GHOUT"; then
    ok "$CASE: GITHUB_OUTPUT has '$1'"
  else
    no "$CASE: GITHUB_OUTPUT has '$1'" "GITHUB_OUTPUT: $GHOUT"
  fi
}

assert_ghout_empty() {
  if [ -z "$GHOUT" ]; then
    ok "$CASE: GITHUB_OUTPUT empty"
  else
    no "$CASE: GITHUB_OUTPUT empty" "GITHUB_OUTPUT: $GHOUT"
  fi
}

assert_built() {
  if [ -f "${CWD}/burrito_out/vzbeam" ]; then
    ok "$CASE: build happened"
  else
    no "$CASE: build happened" "artifact missing"
  fi
}

assert_not_built() {
  if [ -f "${CWD}/burrito_out/vzbeam" ]; then
    no "$CASE: no build" "artifact created"
  else
    ok "$CASE: no build"
  fi
}

run_case "local-no-publish" 0 absent absent ok
assert_rc 0
assert_out_has "not publishing"
assert_log_lacks "release create"
assert_built
# key-signed with a throwaway key, kept out of Rekor, verified against that key
assert_log_has "packslip keygen --out"
assert_log_has "--key"
assert_log_has "--no-log"
assert_log_has "--allow-unlogged --artifact burrito_out/vzbeam"
assert_ghout_empty

run_case "dry-run-in-ci-no-publish" 1 absent absent ok
# Re-run the same CI setup with --dry-run (mise passes it as usage_dry_run), on a fresh log.
: > "$GH_LOG"
OUT="$(cd "$CWD" && PATH="${CWD}/bin:${PATH}" usage_dry_run=true bash "$RELEASE" 2>&1)"
RC=$?
LOG="$(cat "$GH_LOG")"
assert_rc 0
assert_out_has "dry-run"
assert_log_has "--no-log"
assert_log_lacks "release create"
assert_log_lacks "gh api"

run_case "tag-absent-create" 1 absent absent ok
assert_rc 0
assert_log_has "release create"
assert_out_has "created"
assert_built
# keyless (OIDC) signing, verified against this repository's workflow identity
assert_log_lacks "--key"
assert_log_lacks "--no-log"
assert_log_has "--provenance vzbeam=https://api.github.com/repos/djgoku/vzbeam/attestations/sha256:"
assert_log_has "--identity-prefix https://github.com/djgoku/vzbeam/ --issuer https://token.actions.githubusercontent.com"
assert_log_has "--latest --title v0.1.0"
assert_log_lacks "--prerelease"
assert_log_has "burrito_out/vzbeam burrito_out/SHA256SUMS burrito_out/packslip/packslip.sigstore.json"
assert_ghout_has "created=true"

run_case "rc-from-branch-prerelease" 1 absent absent ok 0.3.2-rc.1 refs/heads/feat/x
assert_rc 0
assert_log_has "release create v0.3.2-rc.1 --target deadbeef --prerelease --latest=false"
assert_log_has "--version 0.3.2-rc.1"
assert_ghout_has "created=true"
assert_built

run_case "stable-from-branch-abort" 1 absent absent ok 0.3.2 refs/heads/feat/x
assert_rc 1
assert_out_has "stable releases publish only from main"
assert_log_lacks "gh api"
assert_not_built

# signing fails closed: built, but nothing is published
run_case "sign-fail-abort" 1 absent absent ok 0.1.0 refs/heads/main fail
assert_rc 1
assert_built
assert_log_lacks "packslip verify"
assert_log_lacks "release create"
assert_ghout_empty

run_case "present-nobundle-abort" 1 present nobundle ok
assert_rc 1
assert_out_has "ABORT"
assert_log_lacks "release create"
assert_not_built

run_case "create-race-ok" 1 absent complete fail
assert_rc 0
assert_log_has "release create"
assert_out_has "concurrently"
assert_built
# the concurrent winner attests its own build, not this run
assert_ghout_empty

run_case "create-fail-abort" 1 absent partial fail
assert_rc 1
assert_out_has "ABORT"
assert_log_has "release create"
assert_built

run_case "present-complete-skip" 1 present complete ok
assert_rc 0
assert_out_has "already released"
assert_log_lacks "release create"
assert_not_built

run_case "present-partial-abort" 1 present partial ok
assert_rc 1
assert_out_has "ABORT"
assert_log_lacks "release create"
assert_not_built

run_case "present-reldeleted-abort" 1 present absent ok
assert_rc 1
assert_out_has "ABORT"
assert_not_built

run_case "present-draft-abort" 1 present draft ok
assert_rc 1
assert_out_has "ABORT"
assert_not_built

run_case "present-assets-error-abort" 1 present assets-error ok
assert_rc 1
assert_out_has "ABORT"
assert_log_lacks "release create"
assert_not_built

run_case "tag-unknown-abort" 1 error absent ok
assert_rc 1
assert_out_has "ABORT"
assert_not_built

# tag absent -> build + create fails -> re-check returns unknown (release view errors) -> abort
run_case "create-fail-recheck-unknown" 1 absent error fail
assert_rc 1
assert_out_has "ABORT"
assert_log_has "release create"
assert_built

echo "-----------------------------"
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" = "0" ]
