#!/usr/bin/env bash
# E-C: parameterized threshold feedback controller. Pins all knobs (never relies on the
# placeholder defaults), proves: decision law (hold/up/down vs deadband), pluggable scoring
# registry, NO numeric literal in decide(), apply guards (deadband/safety-band/env-pin/dwell),
# and the threshold_applied event.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
CTRL="$REPO/lib/threshold-controller.sh"
PASS=0; FAIL=0
_aeq(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }
_ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export BATON_EVENT_LOG="$TMP/events.jsonl" BATON_COLLECT=1
mkdir -p "$XDG_CONFIG_HOME/baton"
# Pin knobs: setpoint 0, deadband 1, step 2, band [10,50], dwell 0 (no rate-limit in test).
_pin(){ printf '%s' "$1" > "$XDG_CONFIG_HOME/baton/config.json"; }
BASE='{"tune_setpoint":0,"tune_deadband":1,"tune_step":2,"tune_safety_min":10,"tune_safety_max":50,"tune_dwell_seconds":0'

source "$CTRL"
_ok 'decide defined'     'declare -f threshold_controller::decide >/dev/null'
_ok 'apply defined'      'declare -f threshold_controller::apply >/dev/null'
_ok 'run_once defined'   'declare -f threshold_controller::run_once >/dev/null'
_ok 'score_hold defined' 'declare -f threshold_controller::score_hold >/dev/null'

# --- decision law (current=30, band-interior) ---
_pin "$BASE,\"tune_score_fn\":\"score_hold\"}"
unset BATON_PCT_THRESHOLD
_aeq 'hold 30' "$(threshold_controller::decide 30 0)"   'score==setpoint -> hold'
_aeq 'hold 30' "$(threshold_controller::decide 30 1)"   'within deadband -> hold'
_aeq 'down 28' "$(threshold_controller::decide 30 50)"  'score>setpoint+deadband -> step down by step'
_aeq 'up 32'   "$(threshold_controller::decide 30 -50)" 'score<setpoint-deadband -> step up by step'

# --- pluggable scoring registry: same loop, swapped fn -> different decision ---
_pin "$BASE,\"tune_score_fn\":\"score_above\"}"
_aeq 'down' "$(threshold_controller::run_once | awk '{print $1}')" 'score_above -> step down'
_pin "$BASE,\"tune_score_fn\":\"score_below\"}"
_aeq 'up'   "$(threshold_controller::run_once | awk '{print $1}')" 'score_below -> step up (no loop edit)'

# --- NO numeric literal in the decision function (CC5) ---
# Strip positional-parameter refs ($1/$2/${3}) FIRST -- they are arguments, not magic
# numbers. Any digit that survives is a real literal in the control law.
body=$(declare -f threshold_controller::decide | sed 's/#.*//' | sed -E 's/[$][{]?[0-9]+[}]?//g')
_aeq '' "$(printf '%s' "$body" | grep -oE '[0-9]+' | tr '\n' ' ' | sed 's/ *$//')" 'decide() has no numeric literal (positionals stripped first)'

# --- apply guards ---
# (a) deadband: hold action never persists/changes config
_pin "$BASE,\"tune_score_fn\":\"score_hold\"}"
threshold_controller::apply 30 30 hold 0
_aeq 'null' "$(jq -r '.threshold_pct // "null"' "$XDG_CONFIG_HOME/baton/config.json")" 'hold does not write threshold_pct'
# (b) inside band: a real step persists via _cfg::set AND emits threshold_applied
rm -f "$BATON_EVENT_LOG"
threshold_controller::apply 30 28 down 50
_aeq '28' "$(jq -r '.threshold_pct' "$XDG_CONFIG_HOME/baton/config.json")" 'in-band step persists new threshold'
_aeq 'threshold_applied' "$(jq -r 'select(.event=="threshold_applied").event' "$BATON_EVENT_LOG" | tail -1)" 'apply emits threshold_applied'
_aeq '28' "$(jq -r 'select(.event=="threshold_applied").data.new_threshold' "$BATON_EVENT_LOG" | tail -1)" 'event carries new_threshold'
# (c) outside safety band: refuse to apply (proposed below safety_min)
_pin "$BASE,\"tune_score_fn\":\"score_hold\"}"
threshold_controller::apply 10 8 down 50
_aeq 'null' "$(jq -r '.threshold_pct // "null"' "$XDG_CONFIG_HOME/baton/config.json")" 'below-band proposal is refused (no write)'
# (d) env pin hard-overrides: BATON_PCT_THRESHOLD set suppresses auto-apply
_pin "$BASE,\"tune_score_fn\":\"score_hold\"}"
export BATON_PCT_THRESHOLD=35
threshold_controller::apply 30 28 down 50
_aeq 'null' "$(jq -r '.threshold_pct // "null"' "$XDG_CONFIG_HOME/baton/config.json")" 'env pin suppresses auto-apply'
unset BATON_PCT_THRESHOLD

# --- run_once reports applied vs guard-suppressed (review fix #1) ---
rm -f "$XDG_STATE_HOME/baton/threshold-tune-state.json"
_pin "$BASE,\"tune_score_fn\":\"score_above\",\"threshold_pct\":30}"
_ok 'run_once marks an applied change' 'threshold_controller::run_once | grep -q "\[applied\]"'
# immediately re-run with a long dwell: the prior apply was just recorded, so dwell blocks
_pin '{"tune_setpoint":0,"tune_deadband":1,"tune_step":2,"tune_safety_min":10,"tune_safety_max":50,"tune_dwell_seconds":86400,"tune_score_fn":"score_above","threshold_pct":28}'
_ok 'run_once marks a dwell-suppressed change' 'threshold_controller::run_once | grep -q "suppressed:dwell"'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
