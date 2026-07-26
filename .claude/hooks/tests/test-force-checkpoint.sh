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

WT="$(cd "$(dirname "$0")/.." && pwd)/checkpoint-write-trigger.sh"
mkproj(){
  local d; d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking/workstreams" "$d/docs/sessions/.tracking/terminals" "$d/projects"
  mkdir -p "$d/share/templates" && : > "$d/share/templates/free.md"
  echo "$d"
}
seed_terminal(){  # <tracking> <term_id> <ws> <display>
  local tracking="$1" term_id="$2" ws="$3" display="${4:-}" th
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/workstream-lib.sh"
  th=$(USER=u CLAUDE_TERMINAL_ID="$term_id" term_hash)
  jq -n --arg tid "$term_id" --arg ws "$ws" \
    '{terminal_id:$tid, workstream:$ws, updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n --arg ws "$ws" --arg dn "$display" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/${ws}.json"
}
run_ckpt(){  # <proj> <sid> <file>
  printf '{"session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$2" "$1" "$3" \
    | USER=u CLAUDE_TERMINAL_ID=CTerm CLAUDE_PROJECT_DIR="$1" \
      BATON_DIR="$1/docs/sessions/.tracking" bash "$WT" 2>/dev/null
}

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

# 9. Force on an already-PENDING (owed) session takes the re-assert path, not a fresh trigger.
sid="force-pending-$$"; clean "$sid"
touch "/tmp/claude-context-triggered-${sid}"   # checkpoint already owed (FLAG set)
: > "/tmp/baton-pending-${sid}"                  # pending, still unsaved (empty)
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null
ok "force on PENDING nudges without counting (no counter file)" "[ ! -f /tmp/baton-nag-${sid} ]"
ok "force on PENDING does not rewrite pending" "[ ! -s /tmp/baton-pending-${sid} ]"
ok "force flag consumed on PENDING session" "[ ! -f /tmp/baton-force-checkpoint-${sid} ]"
clean "$sid"

# 10. E1: an ARMED (manual) checkpoint still nudges (soft re-assert); an automated one is silent.
#    Neither path counts anymore - the nag counter is retired. run_hook's default tool
#    is Bash, which is consequential and non-exempt.
sid="e1-manual-$$"; clean "$sid"
echo 95 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/baton-force-checkpoint-${sid}"
run_hook "$sid" >/dev/null            # arms: consumes force flag, writes baton-manual
ok "arming writes the manual marker" "[ -f /tmp/baton-manual-${sid} ]"
run_hook "$sid" >/dev/null            # first re-assert on the owed checkpoint
ok "manual path nudges without counting" "[ ! -f /tmp/baton-nag-${sid} ]"
clean "$sid"; rm -f "/tmp/baton-manual-${sid}"

sid="e1-auto-$$"; clean "$sid"; rm -f "/tmp/baton-manual-${sid}"
echo 95 > "/tmp/claude-context-pct-${sid}"
run_hook "$sid" >/dev/null            # threshold arm, no force flag -> no manual marker
ok "threshold arming writes no manual marker" "[ ! -f /tmp/baton-manual-${sid} ]"
outE1=$(run_hook "$sid")
ok "automated re-assert creates no counter file" "[ ! -f /tmp/baton-nag-${sid} ]"
ok "automated re-assert does not deny" "! printf '%s' \"$outE1\" | grep -q '\"deny\"'"
for _ in 1 2 3 4 5; do outE1=$(run_hook "$sid"); done
ok "automated path still no counter after repeated fires" "[ ! -f /tmp/baton-nag-${sid} ]"
ok "automated path still does not deny after repeated fires" "! printf '%s' \"$outE1\" | grep -q '\"deny\"'"
clean "$sid"; rm -f "/tmp/baton-manual-${sid}"

# E2-ORDER: consent strictly follows the write, across a full manual cycle.
# Drives BOTH hooks: context-checkpoint.sh for the owed state, then
# checkpoint-write-trigger.sh for the write, then the resolver.
PROJ=$(mkproj)
seed_terminal "$PROJ/docs/sessions/.tracking" CTerm alpha-ws alpha
sid="e2-order-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" \
      "/tmp/baton-manual-${sid}"

# 1. Checkpoint owed: a consequential tool must not be asked for consent yet.
# shellcheck disable=SC2034  # read via \$pre inside the eval'd ok condition below
pre=$(run_hook "$sid" Bash)
ok "E2-ORDER no ask while owed" "! printf '%s' \"\$pre\" | grep -q '\"ask\"'"
ok "E2-ORDER no consent marker before the write" "[ ! -f /tmp/baton-consent-${sid} ]"

# 2. The progress write lands.
F="$PROJ/docs/sessions/progress-alpha-ws-e2.md"; echo "# ok" > "$F"
run_ckpt "$PROJ" "$sid" "$F" >/dev/null
ok "E2-ORDER consent outstanding after the write" "[ -f /tmp/baton-consent-${sid} ]"
ok "E2-ORDER DONE deferred after the write"       "[ ! -f /tmp/baton-done-${sid} ]"

# 3. Consent is offered exactly once - resolving it consumes it.
CLAUDE_CODE_SESSION_ID="$sid" bash "$REPO/tools/baton-consent.sh" keep >/dev/null 2>&1
ok "E2-ORDER keep resolves consent once" "[ ! -f /tmp/baton-consent-${sid} ]"
ok "E2-ORDER keep re-arms the trigger"   "[ ! -f /tmp/claude-context-triggered-${sid} ]"

# 4. After keep, work continues unblocked.
# shellcheck disable=SC2034  # read via \$post inside the eval'd ok condition below
post=$(run_hook "$sid" Bash)
ok "E2-ORDER keep leaves the session unblocked" \
   "! printf '%s' \"\$post\" | grep -q '\"deny\"'"

clean "$sid"; rm -f "/tmp/baton-consent-${sid}" "/tmp/baton-manual-${sid}"
rm -rf "$PROJ"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
