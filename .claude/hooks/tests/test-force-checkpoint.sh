#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
HOOK="$REPO/.claude/hooks/context-checkpoint.sh"
ARM="$REPO/tools/baton-checkpoint-now.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export USER="${USER:-tester}"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }
run_hook(){ printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":{}}' \
  "$1" "$TMP" "${2:-Bash}" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null; }
clean(){ rm -f "/tmp/claude-context-pct-$1" "/tmp/claude-context-triggered-$1" \
  "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/baton-force-checkpoint-$1" \
  "/tmp/baton-nag-$1" "/tmp/baton-health-$1" "/tmp/baton-warned-$1"; }

# 1. Force flag fires a checkpoint well below threshold.
sid="force-below-$$"; clean "$sid"
echo 5 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null
ok "force triggers below threshold (FLAG set)" "[ -f /tmp/claude-context-triggered-${sid} ]"
ok "force sets pending marker" "[ -f /tmp/baton-pending-${sid} ]"
ok "force flag consumed (one-shot)" "[ ! -f /tmp/baton-force-checkpoint-${sid} ]"
clean "$sid"

# 2. Force fires even with NO pct value at all (statusline absent).
sid="force-nopct-$$"; clean "$sid"
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null
ok "force triggers with no pct" "[ -f /tmp/claude-context-triggered-${sid} ]"
clean "$sid"

# 3. Regression: no force + below threshold => no trigger.
sid="noforce-$$"; clean "$sid"
echo 5 > "/tmp/claude-context-pct-${sid}"
run_hook "$sid" >/dev/null
ok "below threshold without force does not trigger" "[ ! -f /tmp/claude-context-triggered-${sid} ]"
clean "$sid"

# 4. Arm script writes the correctly-named per-session flag.
sid="arm-$$"; clean "$sid"
CLAUDE_CODE_SESSION_ID="$sid" bash "$ARM" >/dev/null 2>&1
ok "arm script creates the session force flag" "[ -f /tmp/baton-force-checkpoint-${sid} ]"
clean "$sid"

# 5. Arm script refuses when session id is absent.
CLAUDE_CODE_SESSION_ID="" bash "$ARM" >/dev/null 2>&1; rc=$?
ok "arm refuses without session id (rc=1)" "[ $rc -eq 1 ]"

# 6. Arm script rejects a session id with /tmp-unsafe characters (path-injection guard).
CLAUDE_CODE_SESSION_ID="a/b;rm" bash "$ARM" >/dev/null 2>&1; rc=$?
ok "arm rejects malformed session id (rc=1)" "[ $rc -eq 1 ]"

# 7. Redundant force is ignored on a session that already checkpointed (DONE guard wins).
sid="force-done-$$"; clean "$sid"
touch "/tmp/baton-done-${sid}"
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null
ok "force does not re-trigger a DONE session" "[ ! -f /tmp/claude-context-triggered-${sid} ]"
clean "$sid"

# 8. End-to-end contract: arm via the real script, then the hook for the SAME id fires + consumes.
sid="chain-$$"; clean "$sid"
CLAUDE_CODE_SESSION_ID="$sid" bash "$ARM" >/dev/null 2>&1
run_hook "$sid" >/dev/null
ok "armed session triggers on next hook fire" "[ -f /tmp/claude-context-triggered-${sid} ]"
ok "armed flag consumed after hook fire" "[ ! -f /tmp/baton-force-checkpoint-${sid} ]"
clean "$sid"

# 9. Force on an already-PENDING (owed) session takes the nag re-assert path, not a fresh trigger.
sid="force-pending-$$"; clean "$sid"
touch "/tmp/claude-context-triggered-${sid}"   # checkpoint already owed (FLAG set)
: > "/tmp/baton-pending-${sid}"                  # pending, still unsaved (empty)
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null
ok "force on PENDING nags (no fresh trigger)" "[ -f /tmp/baton-nag-${sid} ]"
ok "force on PENDING does not rewrite pending" "[ ! -s /tmp/baton-pending-${sid} ]"
ok "force flag consumed on PENDING session" "[ ! -f /tmp/baton-force-checkpoint-${sid} ]"
clean "$sid"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
