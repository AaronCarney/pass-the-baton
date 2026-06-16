#!/usr/bin/env bash
# test-recommend-insufficient-outcome.sh - fixture test: insufficient outcome data.
# Fixture: events-insufficient.jsonl
#   earliest outcome_proxy ts = 2026-05-24T00:00:00Z
#   CC_NOW = 2026-05-29 → post_e16_days = 5 → N = 30 - 5 = 25 more days needed.
# Also verifies closed-upper boundary: post_e16_days==30 → outcome_data_insufficient==false.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Run with CC_NOW pinned ──
human_out=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-insufficient.jsonl" \
  --corpus /nonexistent \
  --human 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && _pass "exit 0" || _fail "exit 0 (got $rc)"

# Assert "N more days needed" with N==25
printf '%s' "$human_out" | grep -qi 'more days needed' \
  && _pass "human output contains 'more days needed'" \
  || _fail "human output contains 'more days needed' (got: $human_out)"

days_needed=$(printf '%s' "$human_out" | grep -oi '[0-9]* more days needed' | grep -o '^[0-9]*' || echo "")
if [ -n "$days_needed" ]; then
  [ "$days_needed" -eq 25 ] && _pass "N==25 exactly (30 - 5 post_e16_days)" \
    || _fail "N==25 (got: $days_needed)"
else
  _fail "could not extract N from: $human_out"
fi

# Assert cost and time recommendations still present (outcome insufficient doesn't block them)
printf '%s' "$human_out" | grep -qi 'cost-optimal\|time-optimal' \
  && _pass "cost+time recommendations present" \
  || _fail "cost+time recommendations present (got: $human_out)"

# ── JSON: caveats.outcome_data_insufficient==true ──
json_out=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-insufficient.jsonl" \
  --corpus /nonexistent \
  --json 2>/dev/null)

insuff=$(printf '%s' "$json_out" | jq -r '.caveats.outcome_data_insufficient | tostring')
[ "$insuff" = "true" ] && _pass "caveats.outcome_data_insufficient==true" \
  || _fail "caveats.outcome_data_insufficient==true (got: $insuff)"

post_days=$(printf '%s' "$json_out" | jq -r '.window.post_e16_days')
[ "$post_days" -eq 5 ] && _pass "window.post_e16_days==5" \
  || _fail "window.post_e16_days==5 (got: $post_days)"

# ── Closed-upper boundary: post_e16_days==30 → NOT insufficient ──
# Build a temp events file where earliest outcome_proxy ts is exactly 30 days before CC_NOW
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/events-boundary30.jsonl" <<'EVENTS'
{"event":"project_boundary","ts":"2026-04-29T00:00:00Z","data":{"kind":"start","session_id":"b1","terminal_id":"t1"}}
{"event":"project_boundary","ts":"2026-04-29T01:00:00Z","data":{"kind":"end","session_id":"b1","terminal_id":"t1"}}
{"event":"outcome_proxy","ts":"2026-04-29T00:00:00Z","data":{"session_id":"b1","subkind":"code_execution","success":true}}
EVENTS

boundary_json=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$TMP/events-boundary30.jsonl" \
  --corpus /nonexistent \
  --json 2>/dev/null)
boundary_insuff=$(printf '%s' "$boundary_json" | jq -r '.caveats.outcome_data_insufficient | tostring')
[ "$boundary_insuff" = "false" ] && _pass "post_e16_days==30 → outcome_data_insufficient==false (closed-upper)" \
  || _fail "post_e16_days==30 → outcome_data_insufficient==false (got: $boundary_insuff)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
