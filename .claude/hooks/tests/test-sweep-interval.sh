#!/usr/bin/env bash
# test-sweep-interval.sh - BATON_SWEEP_INTERVAL_HOURS has a real runtime effect on
# cleanup-cron.sh --if-due, and install-cron.sh surfaces an honest cadence (E-D Task 2).
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
CLEANUP="$REPO_ROOT/tools/cleanup-cron.sh"
INSTALL="$REPO_ROOT/tools/install-cron.sh"

PASS=0; FAIL=0; FAILED_CASES=()
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); echo "  PASS  $name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj" "$TMP/baton" "$TMP/archive"
export BATON_PROJECT_DIR="$TMP/proj"
export BATON_DIR="$TMP/baton"
export BATON_ARCHIVE_DIR="$TMP/archive"
export BATON_CRON_LOG="$TMP/cron.log"

echo "## runtime effect of BATON_SWEEP_INTERVAL_HOURS"

: > "$BATON_CRON_LOG"
bash "$CLEANUP" --if-due >/dev/null 2>&1 || true
assert ".cron-last-run created by initial run" "[ -f '$BATON_DIR/.cron-last-run' ]"

: > "$BATON_CRON_LOG"
BATON_SWEEP_INTERVAL_HOURS=9999 bash "$CLEANUP" --if-due >/dev/null 2>&1 || true
assert "interval=9999h -> 'not due (interval=9999h)' logged" "grep -q 'not due (interval=9999h)' '$BATON_CRON_LOG'"

: > "$BATON_CRON_LOG"
BATON_SWEEP_INTERVAL_HOURS=0 bash "$CLEANUP" --if-due >/dev/null 2>&1 || true
assert "interval=0 -> 'not due' absent (proceeded)" "! grep -q 'not due' '$BATON_CRON_LOG'"
assert "interval=0 -> '=== Done ===' present" "grep -q '=== Done ===' '$BATON_CRON_LOG'"

echo "## honest surface in install-cron.sh --dry-run"

DRYTMP="$(mktemp -d)"
out=$(XDG_CONFIG_HOME="$DRYTMP/config" HOME="$DRYTMP/home" bash "$INSTALL" --dry-run 2>&1)
assert "dry-run does NOT emit malformed '*/48'" "! printf '%s' \"\$out\" | grep -q '\*/48'"
assert "dry-run names BATON_SWEEP_INTERVAL_HOURS" "printf '%s' \"\$out\" | grep -q BATON_SWEEP_INTERVAL_HOURS"
assert "dry-run writes no env file" "[ ! -e '$DRYTMP/config/baton/env' ]"
out12=$(XDG_CONFIG_HOME="$DRYTMP/config" HOME="$DRYTMP/home" BATON_SWEEP_INTERVAL_HOURS=12 bash "$INSTALL" --dry-run 2>&1)
assert "dry-run surfaces configured interval (12h)" "printf '%s' \"\$out12\" | grep -q '12h'"
rm -rf "$DRYTMP"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
