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
# emulate 'mise run build' and 'mise run checksum' by creating dummy artifacts
if [ "${1:-}" = "run" ] && [ "${2:-}" = "build" ]; then
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
        partial|complete|assets-error) echo "false"; exit 0 ;;
        error) echo "release API error" >&2; exit 1 ;;
      esac
      ;;
    *assets*)
      case "${FAKE_REL:-absent}" in
        absent) echo "release not found" >&2; exit 1 ;;
        draft) exit 0 ;;
        partial) echo "vzbeam"; exit 0 ;;
        complete) printf 'vzbeam\nSHA256SUMS\n'; exit 0 ;;
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
  chmod +x "$d/mix" "$d/mise" "$d/gh"
}

# run_case NAME CI(0/1) FAKE_TAG FAKE_REL FAKE_CREATE -> sets globals: RC, OUT, LOG, CWD
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
  export FAKE_TAG="$fake_tag"
  export FAKE_REL="$fake_rel"
  export FAKE_CREATE="$fake_create"
  export GITHUB_SHA="deadbeef"
  if [ "$ci" = "1" ]; then
    export GITHUB_ACTIONS="true"
  else
    unset GITHUB_ACTIONS
  fi
  OUT="$(cd "$work" && PATH="${mock}:${PATH}" bash "$RELEASE" 2>&1)"
  RC=$?
  LOG="$(cat "$GH_LOG")"
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

run_case "tag-absent-create" 1 absent absent ok
assert_rc 0
assert_log_has "release create"
assert_out_has "created"
assert_built

run_case "create-race-ok" 1 absent complete fail
assert_rc 0
assert_log_has "release create"
assert_out_has "concurrently"
assert_built

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
