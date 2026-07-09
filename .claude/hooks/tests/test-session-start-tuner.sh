#!/bin/bash
# E-G: session-start.sh auto-ticks the threshold controller (threshold_controller::run_once)
# in the MAIN session path, gated on collection_on. Proves:
#  (1) collection ON + non-hold scoring fn -> a bounded apply + threshold_applied event;
#  (2) collection OFF -> NO apply, NO event;
#  (3) placeholder score_hold (default) + collection ON -> no change (safe default);
#  (4) subagent (AGENT_SESSION_ID / Case B) session never ticks.
# Knobs are pinned in config.json (never the placeholder defaults); collection is toggled via
# the BATON_COLLECT env var (collection_on reads it env-only, no config layer).
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
thr(){ jq -r '.threshold_pct' "$XDG_CONFIG_HOME/baton/config.json"; }
applied_n(){ jq -r 'select(.event=="threshold_applied")|.event' "$BATON_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' '; }
run_ss(){ # $1 = session_id ; runs the REAL session-start against a fresh temp project
  local sid="$1" proj; proj=$(mktemp -d)
  ( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}" >/dev/null 2>&1 )
  rm -f /tmp/claude-session-tracking-"$sid"; rm -rf "$proj"
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unset BATON_PCT_THRESHOLD AGENT_SESSION_ID

# ---- (1) collection ON + score_below (forces UP-step) -> apply 23->25 + event ----
export XDG_CONFIG_HOME="$TMP/c1" XDG_STATE_HOME="$TMP/s1" BATON_EVENT_LOG="$TMP/e1.jsonl" BATON_COLLECT=1
write_cfg score_below
run_ss "sid-eg-on-$$"
assert "(1) collection ON + score_below applies up-step (23->25)" "[ \"\$(thr)\" = 25 ]"
assert "(1) collection ON emits a threshold_applied event"        "[ \"\$(applied_n)\" -ge 1 ]"

# ---- (2) collection OFF -> no apply, no event ----
export XDG_CONFIG_HOME="$TMP/c2" XDG_STATE_HOME="$TMP/s2" BATON_EVENT_LOG="$TMP/e2.jsonl"
unset BATON_COLLECT
write_cfg score_below
run_ss "sid-eg-off-$$"
assert "(2) collection OFF leaves threshold unchanged (23)" "[ \"\$(thr)\" = 23 ]"
assert "(2) collection OFF emits no threshold_applied event" "[ \"\$(applied_n)\" = 0 ]"

# ---- (3) placeholder score_hold + collection ON -> safe no-op ----
export XDG_CONFIG_HOME="$TMP/c3" XDG_STATE_HOME="$TMP/s3" BATON_EVENT_LOG="$TMP/e3.jsonl" BATON_COLLECT=1
write_cfg score_hold
run_ss "sid-eg-hold-$$"
assert "(3) placeholder score_hold makes the tick a safe no-op (23)" "[ \"\$(thr)\" = 23 ]"
assert "(3) placeholder score_hold emits no threshold_applied event" "[ \"\$(applied_n)\" = 0 ]"

# ---- (4) subagent (Case B) session never ticks even with collection ON + score_below ----
export XDG_CONFIG_HOME="$TMP/c4" XDG_STATE_HOME="$TMP/s4" BATON_EVENT_LOG="$TMP/e4.jsonl" BATON_COLLECT=1
write_cfg score_below
proj4=$(mktemp -d)
( cd "$proj4" && AGENT_SESSION_ID="agent-$$" CLAUDE_PROJECT_DIR="$proj4" \
    bash "$SS" <<<"{\"session_id\":\"sid-eg-sub-$$\",\"cwd\":\"$proj4\"}" >/dev/null 2>&1 )
rm -f /tmp/claude-session-tracking-sid-eg-sub-"$$"; rm -rf "$proj4"
assert "(4) subagent session does not tune (threshold unchanged 23)" "[ \"\$(thr)\" = 23 ]"
assert "(4) subagent session emits no threshold_applied event" "[ \"\$(applied_n)\" = 0 ]"

echo ""; echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
