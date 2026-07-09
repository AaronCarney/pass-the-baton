#!/usr/bin/env bash
# E-C: tools/tune-threshold.sh observable CLI - show / dry-run / once + collection-off warning.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TT="$REPO/tools/tune-threshold.sh"
PASS=0; FAIL=0
_ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" BATON_EVENT_LOG="$TMP/ev.jsonl"
mkdir -p "$XDG_CONFIG_HOME/baton"
# Pin knobs so the run is deterministic; score_above => step down; band interior.
echo '{"threshold_pct":30,"tune_setpoint":0,"tune_deadband":1,"tune_step":2,"tune_safety_min":10,"tune_safety_max":50,"tune_dwell_seconds":0,"tune_score_fn":"score_above"}' > "$XDG_CONFIG_HOME/baton/config.json"
unset BATON_PCT_THRESHOLD BATON_COLLECT

_ok 'syntax ok' "bash -n '$TT'"
# --show: prints current threshold + chosen score fn, mutates nothing
out=$(BATON_COLLECT=1 bash "$TT" --show 2>/dev/null)
_ok 'show prints current threshold' "echo \"$out\" | grep -q 30"
_ok 'show prints score fn'          "echo \"$out\" | grep -q score_above"
_ok 'show does not mutate config'   "[ \"$(jq -r '.threshold_pct' "$XDG_CONFIG_HOME/baton/config.json")\" = 30 ]"
# --dry-run: decides 'down' but never applies
out=$(BATON_COLLECT=1 bash "$TT" --dry-run 2>/dev/null)
_ok 'dry-run reports down' "echo \"$out\" | grep -q down"
_ok 'dry-run does not apply' "[ \"$(jq -r '.threshold_pct' "$XDG_CONFIG_HOME/baton/config.json")\" = 30 ]"
# --once: applies (guards pass) -> threshold_pct moves to 28 and event lands
BATON_COLLECT=1 bash "$TT" --once >/dev/null 2>&1
_ok 'once applies new threshold (28)' "[ \"$(jq -r '.threshold_pct' "$XDG_CONFIG_HOME/baton/config.json")\" = 28 ]"
_ok 'once emits threshold_applied'    "jq -e 'select(.event==\"threshold_applied\")' \"$BATON_EVENT_LOG\" >/dev/null 2>&1"
# collection-off warning on stderr (no arc, BATON_COLLECT unset)
err=$(bash "$TT" --dry-run 2>&1 >/dev/null)
_ok 'warns when collection is off' "echo \"$err\" | grep -qi 'collection'"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
