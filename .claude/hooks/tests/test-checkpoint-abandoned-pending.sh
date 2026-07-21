#!/bin/bash
# SessionEnd must record a checkpoint that was owed but never delivered.
# Before this, cleanup-on-exit.sh contained ZERO log_event calls, so every
# silent-loss path in the checkpoint lifecycle terminated with no evidence.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CO="$HOOKS_DIR/cleanup-on-exit.sh"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
_bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

mkproj() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.baton/workstreams" "$d/.baton/terminals"
  printf '%s' "$d"
}

run_co() {
  local proj="$1" sid="$2"
  jq -n --arg sid "$sid" --arg cwd "$proj" '{session_id:$sid, cwd:$cwd}' | \
    USER=u CLAUDE_TERMINAL_ID="term-$sid" CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/.baton" BATON_ARCHIVE_DIR="$proj/archive" \
    bash "$CO" >/dev/null 2>&1
}

# A1: PENDING set, DONE absent -> abandoned-pending recorded.
proj=$(mkproj); sid="aband-a1-$$"
echo 42 > "/tmp/baton-pending-${sid}"
run_co "$proj" "$sid"
if grep -q 'abandoned-pending' "$proj/.baton/hook-events.jsonl" 2>/dev/null; then
  _ok "A1: abandoned-pending logged when PENDING outlives the session"
else
  _bad "A1: abandoned-pending logged when PENDING outlives the session"
fi
if [ "$(jq -r 'select(.event=="abandoned-pending") | .pct' "$proj/.baton/hook-events.jsonl" 2>/dev/null)" = "42" ]; then
  _ok "A2: recorded pct carries the value from the PENDING flag"
else
  _bad "A2: recorded pct carries the value from the PENDING flag"
fi
rm -f "/tmp/baton-pending-${sid}"

# A3: PENDING set AND DONE set -> a delivered checkpoint, nothing recorded.
proj=$(mkproj); sid="aband-a3-$$"
echo 42 > "/tmp/baton-pending-${sid}"
touch "/tmp/baton-done-${sid}"
run_co "$proj" "$sid"
if grep -q 'abandoned-pending' "$proj/.baton/hook-events.jsonl" 2>/dev/null; then
  _bad "A3: no abandoned-pending when DONE was latched"
else
  _ok "A3: no abandoned-pending when DONE was latched"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

# A4: no PENDING at all -> nothing recorded.
proj=$(mkproj); sid="aband-a4-$$"
run_co "$proj" "$sid"
if grep -q 'abandoned-pending' "$proj/.baton/hook-events.jsonl" 2>/dev/null; then
  _bad "A4: no abandoned-pending when no checkpoint was owed"
else
  _ok "A4: no abandoned-pending when no checkpoint was owed"
fi

# A5: the nag counter must not outlive the session. This is the consumer-side
# assertion for the /tmp/baton-nag-<sid> contract task 2 produces. It is not
# inert bookkeeping: the counter is keyed by session id, so a survivor means a
# session that reuses the id resumes at the escalated count and hard-denies on
# its first tool call. Task 2's own test removes this file by hand, which is
# itself evidence that nothing else does.
proj=$(mkproj); sid="aband-a5-$$"
echo 2 > "/tmp/baton-nag-${sid}"
run_co "$proj" "$sid"
if [ -f "/tmp/baton-nag-${sid}" ]; then
  _bad "A5: nag counter removed on session end"
  rm -f "/tmp/baton-nag-${sid}"
else
  _ok "A5: nag counter removed on session end"
fi

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
