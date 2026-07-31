#!/usr/bin/env bash
# test-progress-retention.sh - two-tier progress archive (E5 item 1). Files older
# than the cold window move from $BATON_ARCHIVE_DIR/progress/<YYYY-MM>/ to
# $BATON_ARCHIVE_DIR/progress-cold/<YYYY-MM>/, by a plain move. Age comes from the
# write timestamp embedded in the basename, NEVER from mtime - the archival move
# rewrites mtime, the embedded timestamp survives it.
#
# Usage: bash .claude/hooks/tests/test-progress-retention.sh
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
CLEANUP="$REPO_ROOT/tools/cleanup-cron.sh"
RESTORE="$REPO_ROOT/tools/restore-workstream.sh"

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
# _cfg::get resolves config.json under $XDG_CONFIG_HOME (lib/config.sh::_cfg::path),
# and this suite drives cleanup-cron.sh eight times. Sandbox it at SUITE scope, not
# per command: without it an operator who has set BATON_PROGRESS_COLD_DAYS in their
# real ~/.config/baton/config.json makes R1 and R2 diverge from the prediction below.
mkdir -p "$TMP/xdg"
export XDG_CONFIG_HOME="$TMP/xdg"

# cleanup-cron.sh Block 1 sweeps the REAL /tmp: it globs /tmp literally and no
# BATON_DIR / BATON_PROJECT_DIR / BATON_ARCHIVE_DIR override redirects it. Pinning
# the TTL absurdly high makes its `find -mmin +N` match nothing, so running this
# suite cannot delete a concurrent Claude session's /tmp state. Block 7 truncates
# the real /tmp/claude-ws-debug.log on size, so its cap is raised for the same
# reason. Without BOTH pins this suite is unsafe to run while other sessions live.
export BATON_TMP_TTL_HOURS=100000000
export _BATON_DEBUG_LOG_MAX_BYTES=999999999999

# Local time on both sides: Block 5 compares `date +%s` against a filename stamp
# parsed as local time, so a UTC fixture would drift by the machine's offset.
# Epoch arithmetic, not relative-date strings, so the numbers stay explicit.
NOW_EPOCH=$(date +%s)
OLD_EPOCH=$((NOW_EPOCH - 2592000))
NEW_EPOCH=$((NOW_EPOCH - 3600))
OLD_STAMP=$(date -d "@$OLD_EPOCH" +%Y%m%d-%H%M%S)
NEW_STAMP=$(date -d "@$NEW_EPOCH" +%Y%m%d-%H%M%S)
OLD_PART=$(date -d "@$OLD_EPOCH" +%Y-%m)
NEW_PART=$(date -d "@$NEW_EPOCH" +%Y-%m)
RECENT="$BATON_ARCHIVE_DIR/progress"
COLD="$BATON_ARCHIVE_DIR/progress-cold"

seed() {
  rm -rf "$RECENT" "$COLD"
  mkdir -p "$RECENT/$OLD_PART" "$RECENT/$NEW_PART"
  printf '## old\n'    > "$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md"
  printf '## new\n'    > "$RECENT/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md"
  printf '## nostamp\n' > "$RECENT/$OLD_PART/progress-legacyws-bbb222.md"
}

echo "## two-tier progress archive sweep"

seed
: > "$BATON_CRON_LOG"
bash "$CLEANUP" >/dev/null 2>&1
assert "R1: file older than the window moved to the cold tier" \
  "[ -f '$COLD/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"
assert "R1: it left the recent tier" \
  "[ ! -f '$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"
assert "R2: file inside the window stayed in the recent tier" \
  "[ -f '$RECENT/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md' ]"
assert "R2: it is not in the cold tier" \
  "[ ! -f '$COLD/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md' ]"
assert "R3: a basename with no embedded timestamp is left alone" \
  "[ -f '$RECENT/$OLD_PART/progress-legacyws-bbb222.md' ]"
assert "R3: the skip is reported, not silent" \
  "grep -q 'Block 5' '$BATON_CRON_LOG'"
assert "R4: cold-tier file is a plain readable markdown copy, not compressed" \
  "grep -q '## old' '$COLD/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' 2>/dev/null"

echo "## age comes from the filename, not from mtime"

# M1: an old-named file whose mtime is NOW must still move. mtime is rewritten by
# the archival move itself, so an mtime-based sweep would never fire on it.
seed
touch "$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md"
bash "$CLEANUP" >/dev/null 2>&1
assert "M1: fresh mtime + old embedded timestamp still moves" \
  "[ -f '$COLD/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"

# M2: a recent-named file with an ancient mtime must NOT move.
seed
touch -d '400 days ago' "$RECENT/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md"
bash "$CLEANUP" >/dev/null 2>&1
assert "M2: ancient mtime + recent embedded timestamp stays" \
  "[ -f '$RECENT/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md' ]"

echo "## the window is configurable"

seed
BATON_PROGRESS_COLD_DAYS=3650 bash "$CLEANUP" >/dev/null 2>&1
assert "C1: a 3650-day window leaves the 30-day-old file in the recent tier" \
  "[ -f '$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"

seed
BATON_PROGRESS_COLD_DAYS=0 bash "$CLEANUP" >/dev/null 2>&1
assert "C2: a 0-day window moves even the 1-hour-old file" \
  "[ -f '$COLD/$NEW_PART/progress-retws-aaa111-${NEW_STAMP}.md' ]"

# C3: a non-integer window must not compute a garbage cutoff. progress_cold_days()
# clamps anything non-numeric back to 7, so the 30-day-old file still moves. This is
# an integration check of task 2's accessor through Block 5, not a unit test of it.
seed
BATON_PROGRESS_COLD_DAYS=abc bash "$CLEANUP" >/dev/null 2>&1
assert "C3: a non-integer window clamps to the 7-day default" \
  "[ -f '$COLD/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"

echo "## a failed cold-tier move is reported, not silent"

# F: a sweep that cannot reach the cold tier must not log byte-identically to an
# idle sweep - that reads as healthy while the recent tier grows unboundedly, the
# exact failure Block 5 exists to prevent. The tier is made unreachable by putting
# a regular file where the cold directory belongs, so both the mkdir -p and the mv
# fail regardless of the running user's privileges. Injected inside this suite's own
# $TMP fixture, never the operator's real archive.
seed
: > "$BATON_CRON_LOG"
bash "$CLEANUP" >/dev/null 2>&1
assert "F0: a healthy sweep reports zero failures" \
  "grep -q 'Block 5:.*0 failed' '$BATON_CRON_LOG'"

seed
rm -rf "$COLD"
: > "$COLD"
: > "$BATON_CRON_LOG"
bash "$CLEANUP" >/dev/null 2>&1
assert "F1: the aged file stays in the recent tier when the move fails" \
  "[ -f '$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"
assert "F2: the Block 5 summary reports the failure count" \
  "grep -q 'Block 5:.*1 failed' '$BATON_CRON_LOG'"
assert "F3: the failing file is named on its own log line" \
  "grep -q \"cold-tier move failed.*progress-retws-aaa111-${OLD_STAMP}.md\" '$BATON_CRON_LOG'"
rm -f "$COLD"

echo "## Block 5 refuses to sweep when the accessor is missing"

# G: cleanup-cron.sh resolves workstream-lib.sh by a path relative to ITSELF, so the
# only way to exercise a lib without progress_cold_days is to mirror the tree and
# strip the accessor from the copy. Without the definedness guard PROG_COLD_DAYS is
# empty, the cutoff arithmetic yields `now`, and every archived file sweeps to cold
# on a script that still exits 0. This is the task-3-landed / task-2-not-landed skew
# window, which session-start.sh reaches via `cleanup-cron.sh --if-due`.
MIRROR="$TMP/mirror"
mkdir -p "$MIRROR/tools" "$MIRROR/.claude/hooks/lib" "$MIRROR/lib"
cp "$REPO_ROOT/tools/cleanup-cron.sh" "$MIRROR/tools/"
cp "$REPO_ROOT/lib/config.sh" "$MIRROR/lib/"
sed '/^progress_cold_days()/,/^}/d' \
  "$REPO_ROOT/.claude/hooks/lib/workstream-lib.sh" > "$MIRROR/.claude/hooks/lib/workstream-lib.sh"
assert "G0: the mirrored lib really lacks the accessor" \
  "! grep -q '^progress_cold_days()' '$MIRROR/.claude/hooks/lib/workstream-lib.sh'"

seed
: > "$BATON_CRON_LOG"
bash "$MIRROR/tools/cleanup-cron.sh" >/dev/null 2>&1
assert "G1: a missing accessor leaves the aged file in the recent tier" \
  "[ -f '$RECENT/$OLD_PART/progress-retws-aaa111-${OLD_STAMP}.md' ]"
assert "G2: the missing accessor is logged as FATAL, not swept silently" \
  "grep -q 'FATAL: progress_cold_days' '$BATON_CRON_LOG'"
assert "G3: later blocks still run - Block 6 refreshes the cron marker" \
  "grep -q 'Block 6' '$BATON_CRON_LOG'"

echo "## restore reaches the cold tier"

seed
bash "$CLEANUP" >/dev/null 2>&1
mkdir -p "$BATON_ARCHIVE_DIR/checkpoint-state/$OLD_PART/workstreams" "$BATON_DIR/workstreams"
PROG_TARGET="$TMP/proj/.baton/progress/progress-retws-aaa111-${OLD_STAMP}.md"
jq -n --arg p "$PROG_TARGET" \
  '{workstream:"retws", display_name:"retws", progress_file:$p, phase:"impl",
    updated_at:"2026-01-01T00:00:00Z"}' \
  > "$BATON_ARCHIVE_DIR/checkpoint-state/$OLD_PART/workstreams/retws.json"
rm -f "$BATON_DIR/workstreams/retws.json"
BATON_PROJECT_DIR="$TMP/proj" bash "$RESTORE" retws >/dev/null 2>&1
assert "S1: restore-workstream recovers a cold-tier progress file" \
  "[ -f '$PROG_TARGET' ]"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
