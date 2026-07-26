#!/usr/bin/env bash
# Verifies SessionEnd + cron sweeps reap the new drain/consent artifacts.
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd -P)"
EXIT="$HOOKS/cleanup-on-exit.sh"
CRON="$REPO/tools/cleanup-cron.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

SID="unit-clean-$$"
PROJ=$(mktemp -d)
mkfiles(){ touch "/tmp/baton-manual-${SID}" "/tmp/baton-unlock-${SID}" "/tmp/baton-snooze-${SID}" "/tmp/baton-consent-${SID}"; \
  mkdir -p "/tmp/baton-subagents-active-${SID}"; : > "/tmp/baton-subagents-active-${SID}/agentQ"; }

# --- SessionEnd removes this session's copies immediately ---
mkfiles
printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" | CLAUDE_PROJECT_DIR="$PROJ" bash "$EXIT" >/dev/null 2>&1
ok "exit reaps manual flag" "[ ! -f /tmp/baton-manual-${SID} ]"
ok "exit reaps unlock flag" "[ ! -f /tmp/baton-unlock-${SID} ]"
ok "exit reaps snooze flag" "[ ! -f /tmp/baton-snooze-${SID} ]"
ok "exit reaps subagent dir" "[ ! -d /tmp/baton-subagents-active-${SID} ]"
# E2a: SessionEnd reaps an unresolved consent marker, like every sibling marker.
ok "E2a exit reaps consent marker" "[ ! -f /tmp/baton-consent-${SID} ]"

# --- cron sweep reaps aged orphans (fixtures are aged past the default TTL) ---
mkfiles
# age them past the sweep window by setting mtime far in the past
touch -d '2 days ago' "/tmp/baton-manual-${SID}" "/tmp/baton-unlock-${SID}" \
  "/tmp/baton-snooze-${SID}" "/tmp/baton-consent-${SID}" "/tmp/baton-subagents-active-${SID}" 2>/dev/null || true
BATON_PROJECT_DIR="$PROJ" bash "$CRON" >/dev/null 2>&1
ok "cron reaps aged manual flag" "[ ! -f /tmp/baton-manual-${SID} ]"
ok "cron reaps aged unlock flag" "[ ! -f /tmp/baton-unlock-${SID} ]"
ok "cron reaps aged snooze flag" "[ ! -f /tmp/baton-snooze-${SID} ]"
ok "cron reaps aged subagent dir" "[ ! -d /tmp/baton-subagents-active-${SID} ]"
# E2b: the TTL sweep actually removes an aged consent marker (drives cleanup-cron.sh,
# not a grep of its source - the sweep is mtime-driven at cleanup-cron.sh:107).
ok "E2b cron sweeps aged consent marker" "[ ! -f /tmp/baton-consent-${SID} ]"

# E2c: a successful MANUAL save must NOT be recorded as abandoned-pending. After the
# write-trigger runs, PENDING is cleared and only the consent marker is outstanding;
# cleanup-on-exit.sh:47 gates the abandoned-pending event on PENDING still present, so
# the event must not fire. Assert on the event log the hook writes under the project's
# .baton dir.
PROJ2=$(mktemp -d); SIDM="unit-clean-manual-$$"
rm -f "/tmp/baton-pending-${SIDM}" "/tmp/baton-done-${SIDM}" "/tmp/baton-consent-${SIDM}"
: > "/tmp/baton-consent-${SIDM}"          # consent outstanding; PENDING and DONE both absent
printf '{"session_id":"%s","cwd":"%s"}' "$SIDM" "$PROJ2" \
  | CLAUDE_PROJECT_DIR="$PROJ2" bash "$EXIT" >/dev/null 2>&1
ok "E2c manual save is not logged abandoned-pending" \
   "! grep -q abandoned-pending \"$PROJ2/.baton/hook-events.jsonl\" 2>/dev/null"
rm -f "/tmp/baton-consent-${SIDM}"; rm -rf "$PROJ2"

rm -rf "$PROJ" "/tmp/baton-manual-${SID}" "/tmp/baton-unlock-${SID}" \
  "/tmp/baton-snooze-${SID}" "/tmp/baton-consent-${SID}" "/tmp/baton-subagents-active-${SID}"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
