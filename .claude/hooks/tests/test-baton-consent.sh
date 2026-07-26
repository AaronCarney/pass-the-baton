#!/usr/bin/env bash
# test-baton-consent.sh - tools/baton-consent.sh resolves post-write manual consent.
# `keep` must also clear the trigger FLAG: after a manual save the write-trigger has
# already cleared PENDING, and context-checkpoint.sh:216-217 exits early whenever FLAG
# is set with PENDING absent. Leaving FLAG set would make the session permanently
# un-checkpointable - no threshold re-arm and no later /renew.
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$REPO/tools/baton-consent.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }

SID="consent-$$"
clean(){ rm -f "/tmp/baton-consent-${SID}" "/tmp/baton-done-${SID}" \
                "/tmp/claude-context-triggered-${SID}"; }
trap clean EXIT

run(){ CLAUDE_CODE_SESSION_ID="${2:-$SID}" bash "$SCRIPT" "$1" >/dev/null 2>&1; }

# C1: `keep` clears the consent marker and does NOT latch DONE.
clean; : > "/tmp/baton-consent-${SID}"
run keep
ok "C1 keep clears consent"        "[ ! -f /tmp/baton-consent-${SID} ]"
ok "C1 keep leaves DONE unlatched" "[ ! -f /tmp/baton-done-${SID} ]"

# C2: `clear` latches DONE and clears the consent marker.
clean; : > "/tmp/baton-consent-${SID}"
run clear
ok "C2 clear clears consent" "[ ! -f /tmp/baton-consent-${SID} ]"
ok "C2 clear latches DONE"   "[ -f /tmp/baton-done-${SID} ]"

# C3: no consent outstanding -> refuse, non-zero, DONE untouched.
clean
CLAUDE_CODE_SESSION_ID="$SID" bash "$SCRIPT" clear >/dev/null 2>&1; rc=$?
ok "C3 refuses with no consent outstanding" "[ '$rc' != 0 ]"
ok "C3 does not latch DONE"                 "[ ! -f /tmp/baton-done-${SID} ]"

# C4: unknown verb -> non-zero, both markers untouched.
clean; : > "/tmp/baton-consent-${SID}"
CLAUDE_CODE_SESSION_ID="$SID" bash "$SCRIPT" maybe >/dev/null 2>&1; rc=$?
ok "C4 unknown verb refuses"        "[ '$rc' != 0 ]"
ok "C4 unknown verb keeps consent"  "[ -f /tmp/baton-consent-${SID} ]"
ok "C4 unknown verb leaves DONE"    "[ ! -f /tmp/baton-done-${SID} ]"

# C5: missing session id -> non-zero, nothing written.
clean; : > "/tmp/baton-consent-${SID}"
( unset CLAUDE_CODE_SESSION_ID; bash "$SCRIPT" clear ) >/dev/null 2>&1; rc=$?
ok "C5 missing session id refuses" "[ '$rc' != 0 ]"
ok "C5 missing session id no DONE" "[ ! -f /tmp/baton-done-${SID} ]"

# C6: malformed session id -> refuse (path-injection guard), mirroring
# tools/baton-unlock.sh and tools/baton-snooze.sh.
CLAUDE_CODE_SESSION_ID='../../etc/x' bash "$SCRIPT" clear >/dev/null 2>&1; rc=$?
ok "C6 malformed session id refuses" "[ '$rc' != 0 ]"

# C7: `keep` clears the trigger FLAG so the threshold can re-arm. THE regression
# guard for the un-checkpointable-session defect.
clean; : > "/tmp/baton-consent-${SID}"; : > "/tmp/claude-context-triggered-${SID}"
run keep
ok "C7 keep clears the trigger FLAG" "[ ! -f /tmp/claude-context-triggered-${SID} ]"

# C8: `clear` leaves the trigger FLAG alone - the DONE guard owns the session from
# here and cleanup-on-exit.sh reaps FLAG at SessionEnd.
clean; : > "/tmp/baton-consent-${SID}"; : > "/tmp/claude-context-triggered-${SID}"
run clear
ok "C8 clear leaves the trigger FLAG" "[ -f /tmp/claude-context-triggered-${SID} ]"

echo "test-baton-consent: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
