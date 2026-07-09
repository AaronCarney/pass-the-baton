#!/usr/bin/env bash
# test-post-subagent-cost.sh - E20-T2 / E24-T5: SubagentStop cost hook.
# Proves the hook reads the SUB-AGENT's OWN transcript (agent_transcript_path),
# NOT the parent session transcript (transcript_path). Production payload carries
# BOTH; reading transcript_path re-leaks the parent's usage under source:subagent.
# Regression uses DISTINCT parent vs sub-agent fixtures so a leak is observable.
# The arc stamp (project_slug/method) is applied by envelope::emit for the
# inherited CLAUDE_TERMINAL_ID - THIS is the CC16 wire.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/post-subagent-cost.sh"
passed=0; failed=0
assert_eq() { [ "$1" = "$2" ] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - expected [$2] got [$1]"; }; }

setup() {
  TMP="$(mktemp -d)"
  export XDG_STATE_HOME="$TMP"
  export BATON_EVENT_LOG="$TMP/events.jsonl"
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
  echo '{"threshold_pct":37}' > "$XDG_CONFIG_HOME/baton/config.json"
  export CLAUDE_TERMINAL_ID="term-t2"
  unset BATON_EVENT_LOG_DISABLE
  # PARENT session transcript - distinct usage + model. Must NOT leak.
  PARENT="$TMP/parent.jsonl"
  printf '%s\n' '{"message":{"role":"user","content":"go"}}' > "$PARENT"
  printf '%s\n' '{"message":{"role":"assistant","model":"claude-parent-x","usage":{"cache_read_input_tokens":48615,"ephemeral_5m_input_tokens":900,"ephemeral_1h_input_tokens":80,"input_tokens":700,"output_tokens":317}}}' >> "$PARENT"
  # SUB-AGENT's OWN transcript - the numbers the hook MUST emit.
  SUB="$TMP/subagent.jsonl"
  printf '%s\n' '{"message":{"role":"user","content":"go"}}' > "$SUB"
  printf '%s\n' '{"message":{"role":"assistant","model":"claude-sub-y","usage":{"cache_read_input_tokens":11,"ephemeral_5m_input_tokens":22,"ephemeral_1h_input_tokens":3,"input_tokens":44,"output_tokens":5}}}' >> "$SUB"
}
teardown() { rm -rf "$TMP"; }

setup
bash "$REPO_ROOT/tools/project.sh" mark-start arc-sub --method none >/dev/null
printf '%s' "{\"session_id\":\"parent-sess\",\"transcript_path\":\"$PARENT\",\"agent_id\":\"a1d5\",\"agent_type\":\"general-purpose\",\"agent_transcript_path\":\"$SUB\"}" | bash "$HOOK"
line="$(grep '"event":"cost_rollup"' "$BATON_EVENT_LOG" 2>/dev/null | tail -n1)"
assert_eq "$([ -n "$line" ] && echo yes)" "yes" "cost_rollup appended"
assert_eq "$(printf '%s' "$line" | jq -r '.data.project_slug')" "arc-sub" "stamped project_slug (CC16)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.method')" "none" "stamped method (CC16)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.cache_read')" "11" "cache_read from sub-agent (no parent leak)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.cache_write_5m')" "22" "cache_write_5m from sub-agent"
assert_eq "$(printf '%s' "$line" | jq -r '.data.cache_write_1h')" "3" "cache_write_1h from sub-agent"
assert_eq "$(printf '%s' "$line" | jq -r '.data.fresh_input')" "44" "fresh_input from sub-agent"
assert_eq "$(printf '%s' "$line" | jq -r '.data.output')" "5" "output from sub-agent (not parent 317)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.source')" "subagent" "source discriminator stamped"
assert_eq "$(printf '%s' "$line" | jq -r '.data.model')" "claude-sub-y" "model from sub-agent (not parent)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.agent_id')" "a1d5" "agent_id stamped"
assert_eq "$(printf '%s' "$line" | jq -r '.data.agent_type')" "general-purpose" "agent_type stamped"
assert_eq "$(printf '%s' "$line" | jq -r '.data.transcript_basename')" "subagent.jsonl" "transcript_basename is sub-agent basename"
assert_eq "$(printf '%s' "$line" | jq -r '.data.threshold')" "37" "active threshold stamped (E-C)"
teardown

setup
printf '%s' "{\"session_id\":\"parent-sess\",\"transcript_path\":\"$PARENT\",\"agent_transcript_path\":\"\"}" | bash "$HOOK"; rc=$?
assert_eq "$rc" "0" "empty agent_transcript_path exits 0"
assert_eq "$([ -s "$BATON_EVENT_LOG" ] && echo nonempty || echo empty)" "empty" "empty agent transcript appends nothing (no parent fallback)"
teardown

setup
printf '%s' "{\"session_id\":\"parent-sess\",\"transcript_path\":\"$PARENT\"}" | bash "$HOOK"; rc=$?
assert_eq "$rc" "0" "missing agent_transcript_path key exits 0"
assert_eq "$([ -s "$BATON_EVENT_LOG" ] && echo nonempty || echo empty)" "empty" "missing agent transcript appends nothing (no parent fallback)"
teardown

setup
export BATON_EVENT_LOG_DISABLE=1
printf '%s' "{\"session_id\":\"parent-sess\",\"transcript_path\":\"$PARENT\",\"agent_id\":\"a1d5\",\"agent_type\":\"general-purpose\",\"agent_transcript_path\":\"$SUB\"}" | bash "$HOOK"
assert_eq "$([ -s "$BATON_EVENT_LOG" ] && echo nonempty || echo empty)" "empty" "disable flag suppresses emit"
teardown

# Flush-race recovery: SubagentStop can fire before the sub-agent's usage-bearing
# assistant line is flushed (observed live dropping ~2/3 of dispatches). The hook
# MUST poll until it appears rather than read a partial transcript and exit.
setup
bash "$REPO_ROOT/tools/project.sh" mark-start arc-race --method none >/dev/null
RACE="$TMP/race.jsonl"
printf '%s\n' '{"message":{"role":"user","content":"go"}}' > "$RACE"  # no usage yet
( sleep 0.4; printf '%s\n' '{"message":{"role":"assistant","model":"claude-sub-y","usage":{"cache_read_input_tokens":11,"ephemeral_5m_input_tokens":22,"ephemeral_1h_input_tokens":3,"input_tokens":44,"output_tokens":5}}}' >> "$RACE" ) &
printf '%s' "{\"session_id\":\"parent-sess\",\"agent_id\":\"a1d5\",\"agent_type\":\"general-purpose\",\"agent_transcript_path\":\"$RACE\"}" \
  | CC16_USAGE_POLL_TRIES=40 CC16_USAGE_POLL_SLEEP=0.05 bash "$HOOK"
wait
line="$(grep '"event":"cost_rollup"' "$BATON_EVENT_LOG" 2>/dev/null | tail -n1)"
assert_eq "$([ -n "$line" ] && echo yes)" "yes" "late-flushed usage still emitted (race recovery)"
assert_eq "$(printf '%s' "$line" | jq -r '.data.output')" "5" "polled output matches sub-agent"
assert_eq "$(printf '%s' "$line" | jq -r '.data.project_slug')" "arc-race" "race-recovery event stamped to arc"
teardown

# Bounded exit: a transcript that never gains a usage line must exit 0 without
# emitting (and without hanging past the poll budget).
setup
NOUSE="$TMP/nouse.jsonl"
printf '%s\n' '{"message":{"role":"user","content":"go"}}' > "$NOUSE"
printf '%s' "{\"session_id\":\"parent-sess\",\"agent_transcript_path\":\"$NOUSE\"}" \
  | CC16_USAGE_POLL_TRIES=2 CC16_USAGE_POLL_SLEEP=0.01 bash "$HOOK"; rc=$?
assert_eq "$rc" "0" "no-usage transcript exits 0 after bounded poll"
assert_eq "$([ -s "$BATON_EVENT_LOG" ] && echo nonempty || echo empty)" "empty" "no-usage transcript appends nothing"
teardown

echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
