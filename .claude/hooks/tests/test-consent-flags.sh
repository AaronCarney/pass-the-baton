#!/usr/bin/env bash
# Consent-escape tests: /off unlock flag + /snooze expiry flag.
#
# Output-capture vars are consumed inside ok()'s eval'd assertion string, which
# static analysis cannot trace, so they read as unused.
# shellcheck disable=SC2034
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
UNLOCK="$REPO/tools/baton-unlock.sh"
SNOOZE="$REPO/tools/baton-snooze.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

# Hook fixture (ported from test-force-checkpoint.sh:3-14). Before E2 this suite
# never drove the hook; the E2 cases below are the first to do so.
HOOK="$REPO/.claude/hooks/context-checkpoint.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
run_hook(){ printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":{}}' \
  "$1" "$TMP" "${2:-Bash}" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null; }
hclean(){ rm -f "/tmp/claude-context-pct-$1" "/tmp/claude-context-triggered-$1" \
  "/tmp/baton-pending-$1" "/tmp/baton-manual-$1" "/tmp/baton-nag-$1" \
  "/tmp/baton-unlock-$1" "/tmp/baton-snooze-$1" "/tmp/baton-consent-$1"; }

SID="unit-consent-$$"
rm -f "/tmp/baton-unlock-${SID}" "/tmp/baton-snooze-${SID}"

# unlock arms the flag
CLAUDE_CODE_SESSION_ID="$SID" bash "$UNLOCK" >/dev/null 2>&1
ok "unlock writes flag" "[ -f /tmp/baton-unlock-${SID} ]"

# unlock refuses a bad session id (no flag written)
rm -f "/tmp/baton-unlock-bad;id"
CLAUDE_CODE_SESSION_ID='bad;id' bash "$UNLOCK" >/dev/null 2>&1
ok "unlock rejects bad id" "! ls /tmp/baton-unlock-bad* >/dev/null 2>&1"

# unlock refuses when session id absent (rc1)
ok "unlock needs session id" "! ( unset CLAUDE_CODE_SESSION_ID; bash \"$UNLOCK\" >/dev/null 2>&1 )"

# snooze writes a future expiry epoch
CLAUDE_CODE_SESSION_ID="$SID" bash "$SNOOZE" 5 >/dev/null 2>&1
ok "snooze writes flag" "[ -f /tmp/baton-snooze-${SID} ]"
EXP=$(cat "/tmp/baton-snooze-${SID}"); NOW=$(date +%s)
ok "snooze expiry in future" "[ \"$EXP\" -gt \"$NOW\" ]"
ok "snooze ~5min out" "[ $((EXP-NOW)) -ge 250 ] && [ $((EXP-NOW)) -le 350 ]"

# snooze default minutes when no arg
rm -f "/tmp/baton-snooze-${SID}"
CLAUDE_CODE_SESSION_ID="$SID" bash "$SNOOZE" >/dev/null 2>&1
EXP=$(cat "/tmp/baton-snooze-${SID}"); NOW=$(date +%s)
ok "snooze default ~10min" "[ $((EXP-NOW)) -ge 550 ] && [ $((EXP-NOW)) -le 650 ]"

# snooze rejects non-numeric minutes (fail loud, no flag)
rm -f "/tmp/baton-snooze-${SID}"
CLAUDE_CODE_SESSION_ID="$SID" bash "$SNOOZE" abc >/dev/null 2>&1
ok "snooze rejects non-numeric" "! [ -f /tmp/baton-snooze-${SID} ]"

# snooze rejects zero minutes (fail loud, no flag)
rm -f "/tmp/baton-snooze-${SID}"
CLAUDE_CODE_SESSION_ID="$SID" bash "$SNOOZE" 0 >/dev/null 2>&1
ok "snooze rejects zero minutes" "! [ -f /tmp/baton-snooze-${SID} ]"

# snooze refuses when session id is absent (rc1)
ok "snooze needs session id" "! ( unset CLAUDE_CODE_SESSION_ID; bash \"$SNOOZE\" 5 >/dev/null 2>&1 )"

# snooze refuses a bad session id (no flag written)
rm -f "/tmp/baton-snooze-bad;id"
CLAUDE_CODE_SESSION_ID='bad;id' bash "$SNOOZE" 5 >/dev/null 2>&1
ok "snooze rejects bad id" "! ls /tmp/baton-snooze-bad* >/dev/null 2>&1"

rm -f "/tmp/baton-unlock-${SID}" "/tmp/baton-snooze-${SID}"

# Hardening (not a reproduced failure): the executor session can carry a BATON_*
# override in its environment. Clear the ones the default-cap cases assert
# against; the lowered-cap case below sets BATON_SNOOZE_MAX_MIN inline instead.
unset BATON_DRAIN_TIMEOUT_SECS BATON_SNOOZE_MAX_MIN

# --- snooze is bounded ---
SIDC="unit-consent-cap-$$"
rm -f "/tmp/baton-snooze-${SIDC}"
CLAUDE_CODE_SESSION_ID="$SIDC" bash "$SNOOZE" 121 >/dev/null 2>&1
ok "snooze rejects over-cap minutes" "[ ! -f /tmp/baton-snooze-${SIDC} ]"
CLAUDE_CODE_SESSION_ID="$SIDC" bash "$SNOOZE" 120 >/dev/null 2>&1
ok "snooze accepts exactly the cap" "[ -f /tmp/baton-snooze-${SIDC} ]"
rm -f "/tmp/baton-snooze-${SIDC}"

# --- bare /snooze uses the default minutes and still arms ---
# Every case above passes an explicit minute value; the no-arg default path
# (baton-snooze.sh:17 `MINUTES="${1:-10}"`, default 10, under the 120 cap) runs
# through the new -gt guard untested otherwise. BATON_SNOOZE_MAX_MIN is unset above.
SIDD="unit-consent-default-$$"
rm -f "/tmp/baton-snooze-${SIDD}"
CLAUDE_CODE_SESSION_ID="$SIDD" bash "$SNOOZE" >/dev/null 2>&1
ok "bare snooze arms with the default minutes" "[ -f /tmp/baton-snooze-${SIDD} ]"
rm -f "/tmp/baton-snooze-${SIDD}"

# --- snooze warns when a checkpoint is already owed ---
SIDP="unit-consent-pending-$$"
rm -f "/tmp/baton-snooze-${SIDP}" "/tmp/baton-pending-${SIDP}"
: > "/tmp/baton-pending-${SIDP}"
SNOOZE_ERR=$(CLAUDE_CODE_SESSION_ID="$SIDP" bash "$SNOOZE" 5 2>&1 >/dev/null)
ok "snooze warns over an owed checkpoint" "printf '%s' \"\$SNOOZE_ERR\" | grep -qi 'unsaved checkpoint'"
ok "snooze still arms despite the warning" "[ -f /tmp/baton-snooze-${SIDP} ]"
rm -f "/tmp/baton-snooze-${SIDP}" "/tmp/baton-pending-${SIDP}"

# --- no pending, no warning ---
SIDQ="unit-consent-nopending-$$"
rm -f "/tmp/baton-snooze-${SIDQ}" "/tmp/baton-pending-${SIDQ}"
QUIET_ERR=$(CLAUDE_CODE_SESSION_ID="$SIDQ" bash "$SNOOZE" 5 2>&1 >/dev/null)
ok "no warning without a pending checkpoint" "! printf '%s' \"\$QUIET_ERR\" | grep -qi 'unsaved checkpoint'"
rm -f "/tmp/baton-snooze-${SIDQ}"

# --- the cap reads BATON_SNOOZE_MAX_MIN, not a hard-coded 120 ---
# Only a lowered env cap proves the code consults the var: the 121/120 cases
# above pass identically whether the bound is the env default or a literal 120.
SIDE="unit-consent-envcap-$$"
rm -f "/tmp/baton-snooze-${SIDE}"
CLAUDE_CODE_SESSION_ID="$SIDE" BATON_SNOOZE_MAX_MIN=5 bash "$SNOOZE" 6 >/dev/null 2>&1
ok "snooze honours a lowered BATON_SNOOZE_MAX_MIN (6 over cap 5)" "[ ! -f /tmp/baton-snooze-${SIDE} ]"
CLAUDE_CODE_SESSION_ID="$SIDE" BATON_SNOOZE_MAX_MIN=5 bash "$SNOOZE" 5 >/dev/null 2>&1
ok "snooze accepts exactly the lowered cap" "[ -f /tmp/baton-snooze-${SIDE} ]"
rm -f "/tmp/baton-snooze-${SIDE}"

# --- E2: consent is a POST-write question now; nothing may `ask` while owed. ---
owe(){ hclean "$1"; echo 50 > "/tmp/claude-context-pct-$1"; \
  touch "/tmp/claude-context-triggered-$1" "/tmp/baton-pending-$1" "/tmp/baton-manual-$1"; }

# E2-A: no `ask` while the checkpoint is still owed. THE red-driver for this task -
# the pre-write menu currently emits `ask` here, and deleting it in step 3 is what
# turns this green.
SIDA="e2-noask-$$"; owe "$SIDA"; A=$(run_hook "$SIDA" Bash); hclean "$SIDA"
ok "E2 no ask while owed" "! printf '%s' \"\$A\" | grep -q '\"ask\"'"

# E2-B: a seeded counter can no longer resurrect an escalation. E3 deleted the
# hard-deny block outright; seed the retired counter past its former limit and prove
# the hook still emits no `deny`. Seeded-counter-past-the-old-limit is the strongest
# fixture in this file for that property - keep it, invert the assertion.
SIDB="e2-deny-$$"; owe "$SIDB"; echo 3 > "/tmp/baton-nag-$SIDB"
B=$(run_hook "$SIDB" Bash); hclean "$SIDB"
ok "E2-B seeded counter cannot resurrect a deny" "! printf '%s' \"\$B\" | grep -q 'deny'"

# E2-C: /pass-the-baton:off (unlock) still no-ops the whole lifecycle while owed -
# the hook exits at its unlock escape with no permissionDecision at all. Real
# evidence for L1 exit gate 3.
SIDU="e2-unlock-$$"; owe "$SIDU"; touch "/tmp/baton-unlock-$SIDU"
U=$(run_hook "$SIDU" Bash); hclean "$SIDU"
ok "E2 unlock no-ops while owed" "! printf '%s' \"\$U\" | grep -qE '\"ask\"|deny'"

# E2-D: /pass-the-baton:snooze (unexpired) still no-ops while owed. Same gate-3
# evidence for the snooze escape.
SIDS="e2-snooze-$$"; owe "$SIDS"; echo $(( $(date +%s) + 3600 )) > "/tmp/baton-snooze-$SIDS"
S=$(run_hook "$SIDS" Bash); hclean "$SIDS"
ok "E2 snooze no-ops while owed" "! printf '%s' \"\$S\" | grep -qE '\"ask\"|deny'"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
