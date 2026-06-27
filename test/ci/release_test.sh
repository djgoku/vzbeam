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
  create-race)
    case "$action" in
      view|create) exit 1 ;;
      upload) exit 0 ;;
    esac
    exit 0 ;;
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

# CI create-race: create fails (lost race) -> recover via upload --clobber
run_case "ci-create-race" create-race 1
assert_rc 0; assert_log_has "release create"; assert_log_has "release upload"

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
