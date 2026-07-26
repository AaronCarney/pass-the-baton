#!/usr/bin/env bash
# Subagent-track + drain-gate tests. Verifies marker create/remove attribution
# through the term_hash -> parent-sid map, and the drain-gate count/clear/age API.
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
START="$HOOKS/subagent-track-start.sh"
STOP="$HOOKS/post-subagent-cost.sh"
source "$HOOKS/lib/drain-gate.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

PSID="sess-parent-abc"
TH="deadbeefdeadbeefdeadbeefdeadbeef"
# term_hash resolves from CLAUDE_TERMINAL_ID; pin it so the hooks map to PSID.
export CLAUDE_TERMINAL_ID="unit-track-tty"
TH=$(printf '%s' "${USER}:${CLAUDE_TERMINAL_ID}" | md5sum | cut -d' ' -f1)
rm -rf "/tmp/baton-subagents-active-${PSID}"; rm -f "/tmp/claude-parent-sid-${TH}"
echo "$PSID" > "/tmp/claude-parent-sid-${TH}"

# clear to start
ok "count 0 when no dir" "[ \"$(drain::count "$PSID")\" = 0 ]"
ok "is_clear true when empty" "drain::is_clear \"$PSID\""

# SubagentStart marks agent A then B
printf '{"agent_id":"agentA","agent_type":"general","session_id":"subA"}' | bash "$START"
printf '{"agent_id":"agentB","agent_type":"general","session_id":"subB"}' | bash "$START"
ok "count 2 after two starts" "[ \"$(drain::count "$PSID")\" = 2 ]"
ok "not clear with 2 active" "! drain::is_clear \"$PSID\""

# SubagentStop for A (no transcript path -> still removes marker)
printf '{"agent_id":"agentA","session_id":"subA"}' | bash "$STOP" >/dev/null 2>&1
ok "count 1 after one stop" "[ \"$(drain::count "$PSID")\" = 1 ]"
printf '{"agent_id":"agentB","session_id":"subB"}' | bash "$STOP" >/dev/null 2>&1
ok "clear after both stop" "drain::is_clear \"$PSID\""

# mark_start rejects a bad agent_id and never touches the filesystem
ok "mark_start rejects bad agent_id" "! drain::mark_start \"$PSID\" 'bad;id'"
ok "mark_start bad id leaves count 0" "[ \"$(drain::count "$PSID")\" = 0 ]"

# subagent-track-start with NO parent-sid map -> exit 0, writes no marker
rm -f "/tmp/claude-parent-sid-${TH}"
printf '{"agent_id":"orphan","session_id":"subO"}' | bash "$START"
ok "no parent map -> no marker written" "[ \"$(drain::count "$PSID")\" = 0 ]"
echo "$PSID" > "/tmp/claude-parent-sid-${TH}"   # restore for the age/hung cases below

# age + hung
printf '{"agent_id":"agentC","session_id":"subC"}' | bash "$START"
ok "oldest_age small when fresh" "[ \"$(drain::oldest_age "$PSID")\" -lt 60 ]"
ok "not hung when fresh" "! drain::hung \"$PSID\""
BATON_DRAIN_TIMEOUT_SECS=0 ok "hung when timeout 0" "BATON_DRAIN_TIMEOUT_SECS=0 drain::hung \"$PSID\""

# bad parent_sid never touches the filesystem
ok "marker_dir rejects bad id" "! drain::marker_dir 'bad;id' >/dev/null 2>&1"

rm -rf "/tmp/baton-subagents-active-${PSID}"; rm -f "/tmp/claude-parent-sid-${TH}"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
