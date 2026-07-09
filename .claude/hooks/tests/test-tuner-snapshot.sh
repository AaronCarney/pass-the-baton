#!/bin/bash
# E-H: session-start.sh emits a `tuner_snapshot` event recording the resolved tuner knob vector,
# inside the collection-gated controller block (after threshold_controller::run_once). Proves:
#  (1) collection ON + score_hold -> exactly ONE tuner_snapshot carrying all 7 knobs + threshold +
#      session_id at the pinned config values (threshold stays 23: hold);
#  (2) collection OFF -> NO tuner_snapshot (the call sits inside the collection gate);
#  (3) subagent (AGENT_SESSION_ID / Case B) -> NO tuner_snapshot (Case B exits before the block);
#  (4) collection ON + score_below (drives a real 23->25 apply) -> snapshot records the POST-apply
#      threshold 25, NOT a stale pre-tick 23 (this is the behavior the epoch exists to make
#      observable: the threshold is read after run_once);
#  (5) collection ON + score_below + BATON_PCT_THRESHOLD pin -> snapshot records the PINNED
#      threshold (the L1 gate's "or BATON_PCT_THRESHOLD-pinned" clause).
# write_cfg takes the scoring fn so run_once can be a no-op (score_hold) or a real step (score_below).
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
PASS=0; FAIL=0; FAILED=()
assert(){ local n="$1" c="$2"; if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"; else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi; }

write_cfg(){ # $1 = score_fn ; threshold_pct=23, band [10,50], step 2, deadband 1, dwell 0
  mkdir -p "$XDG_CONFIG_HOME/baton"
  jq -n --arg fn "$1" \
    '{threshold_pct:23, tune_setpoint:0, tune_deadband:1, tune_step:2,
      tune_safety_min:10, tune_safety_max:50, tune_dwell_seconds:0, tune_score_fn:$fn}' \
    > "$XDG_CONFIG_HOME/baton/config.json"
}
snap_n(){ jq -r 'select(.event=="tuner_snapshot")|.event' "$BATON_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' '; }
snap(){ jq -r "select(.event==\"tuner_snapshot\")|.data.$1" "$BATON_EVENT_LOG" 2>/dev/null | head -1; }
run_ss(){ local sid="$1" proj; proj=$(mktemp -d)
  ( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}" >/dev/null 2>&1 )
  rm -f /tmp/claude-session-tracking-"$sid"; rm -rf "$proj"
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unset BATON_PCT_THRESHOLD AGENT_SESSION_ID

# ---- (1) collection ON + score_hold -> one snapshot, full pinned vector, threshold held at 23 ----
export XDG_CONFIG_HOME="$TMP/c1" XDG_STATE_HOME="$TMP/s1" BATON_EVENT_LOG="$TMP/e1.jsonl" BATON_COLLECT=1
write_cfg score_hold
SID="sid-eh-on-$$"
run_ss "$SID"
assert "(1) collection ON emits exactly one tuner_snapshot" "[ \"\$(snap_n)\" = 1 ]"
assert "(1) snapshot carries this session_id"               "[ \"\$(snap session_id)\" = \"$SID\" ]"
assert "(1) snapshot threshold = 23 (post-tick, hold)"      "[ \"\$(snap threshold)\" = 23 ]"
assert "(1) snapshot setpoint = 0"        "[ \"\$(snap setpoint)\" = 0 ]"
assert "(1) snapshot deadband = 1"        "[ \"\$(snap deadband)\" = 1 ]"
assert "(1) snapshot step = 2"            "[ \"\$(snap step)\" = 2 ]"
assert "(1) snapshot safety_min = 10"     "[ \"\$(snap safety_min)\" = 10 ]"
assert "(1) snapshot safety_max = 50"     "[ \"\$(snap safety_max)\" = 50 ]"
assert "(1) snapshot dwell_seconds = 0"   "[ \"\$(snap dwell_seconds)\" = 0 ]"
assert "(1) snapshot score_fn = score_hold" "[ \"\$(snap score_fn)\" = score_hold ]"
assert "(1) snapshot collect = 1"         "[ \"\$(snap collect)\" = 1 ]"

# ---- (2) collection OFF -> no snapshot ----
export XDG_CONFIG_HOME="$TMP/c2" XDG_STATE_HOME="$TMP/s2" BATON_EVENT_LOG="$TMP/e2.jsonl"
unset BATON_COLLECT
write_cfg score_hold
run_ss "sid-eh-off-$$"
assert "(2) collection OFF emits no tuner_snapshot" "[ \"\$(snap_n)\" = 0 ]"

# ---- (3) subagent (Case B) -> no snapshot even with collection ON ----
export XDG_CONFIG_HOME="$TMP/c3" XDG_STATE_HOME="$TMP/s3" BATON_EVENT_LOG="$TMP/e3.jsonl" BATON_COLLECT=1
write_cfg score_below
proj3=$(mktemp -d)
( cd "$proj3" && AGENT_SESSION_ID="agent-$$" CLAUDE_PROJECT_DIR="$proj3" \
    bash "$SS" <<<"{\"session_id\":\"sid-eh-sub-$$\",\"cwd\":\"$proj3\"}" >/dev/null 2>&1 )
rm -f /tmp/claude-session-tracking-sid-eh-sub-"$$"; rm -rf "$proj3"
assert "(3) subagent session emits no tuner_snapshot" "[ \"\$(snap_n)\" = 0 ]"

# ---- (4) collection ON + score_below -> run_once applies 23->25; snapshot records POST-apply 25 ----
export XDG_CONFIG_HOME="$TMP/c4" XDG_STATE_HOME="$TMP/s4" BATON_EVENT_LOG="$TMP/e4.jsonl" BATON_COLLECT=1
write_cfg score_below
run_ss "sid-eh-apply-$$"
assert "(4) snapshot records the post-apply threshold 25 (not stale 23)" "[ \"\$(snap threshold)\" = 25 ]"
assert "(4) collection ON still emits exactly one tuner_snapshot"        "[ \"\$(snap_n)\" = 1 ]"

# ---- (5) collection ON + score_below + env pin -> snapshot records the pinned threshold ----
export XDG_CONFIG_HOME="$TMP/c5" XDG_STATE_HOME="$TMP/s5" BATON_EVENT_LOG="$TMP/e5.jsonl" BATON_COLLECT=1
write_cfg score_below
BATON_PCT_THRESHOLD=30 run_ss "sid-eh-pin-$$"
assert "(5) snapshot records the BATON_PCT_THRESHOLD-pinned threshold 30" "[ \"\$(snap threshold)\" = 30 ]"

echo ""; echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
