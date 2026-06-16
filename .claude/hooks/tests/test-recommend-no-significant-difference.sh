#!/usr/bin/env bash
# test-recommend-no-significant-difference.sh - fixture test: no significant difference.
# Tests the no_significant_difference detection path in recommend::aggregate.
# NOTE: The no-sig-diff scenario cannot be reproduced end-to-end through recommend.sh
# because the replay_harness cost model ensures compact >= clear_only for every session
# (compact boundary adds cost, never subtracts). To exercise the detection logic this
# test calls recommend::aggregate directly with synthetic arm files where compact and
# clear_only have mixed ordering, producing a CI that straddles zero. The smoke test
# (exit 0 on --json) is separately verified via test-recommend-integration.sh.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# Source libs required by recommend::aggregate
source "$REPO/lib/stats-bootstrap.sh"
source "$REPO/lib/release-dates.sh"
source "$REPO/lib/recommend-cost-extract.sh"
source "$REPO/lib/recommend-time-extract.sh"
source "$REPO/lib/recommend-outcome-extract.sh"
source "$REPO/lib/recommend-paired-deltas.sh"
source "$REPO/lib/recommend-threshold-sweep.sh"
source "$REPO/lib/recommend-aggregate.sh"
source "$REPO/lib/recommend-format.sh"

# ── Build synthetic arm files where compact and clear_only swap ordering ──
# compact < clear_only in some sessions, compact > clear_only in others
# → mean_diff ≈ 0, high variance → CI straddles zero
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARMS="$TMP/arms"
mkdir -p "$ARMS"

# 10 sessions: 5 where compact < clear_only, 5 where compact > clear_only
# compact values: 0.020 0.020 0.020 0.020 0.020 | 0.060 0.060 0.060 0.060 0.060
# clear_only:     0.060 0.060 0.060 0.060 0.060 | 0.020 0.020 0.020 0.020 0.020
# mean diff (compact - clear_only) = 0 exactly → CI straddling zero expected
for i in $(seq 1 5); do
  printf '{"slug":"s%s","value":0.020}\n' "$i" >> "$ARMS/arm-compact.jsonl"
  printf '{"slug":"s%s","value":0.060}\n' "$i" >> "$ARMS/arm-clear_only.jsonl"
done
for i in $(seq 6 10); do
  printf '{"slug":"s%s","value":0.060}\n' "$i" >> "$ARMS/arm-compact.jsonl"
  printf '{"slug":"s%s","value":0.020}\n' "$i" >> "$ARMS/arm-clear_only.jsonl"
done

# Minimal cost JSON with per_arm_per_subset (equal cost → no winner from cost alone)
COST_JSON="$TMP/cost.json"
printf '{
  "schema_version":3,"method":"baton-threshold","model":"claude-sonnet-4-6",
  "transcripts":[],
  "aggregates":{"22":{"median":0.04,"mean":0.04,"p95":0.04,"iqr":0.0,"count":10}},
  "per_arm_per_subset":[
    {"arm":"compact","subset":"clean","usd_total":"0.040","session_count":10},
    {"arm":"clear_only","subset":"clean","usd_total":"0.041","session_count":10}
  ],
  "typical_best":{"median":22,"mode":22},"disclaimer":"fixture"
}\n' > "$COST_JSON"

# Empty time/outcome JSON
printf '{"per_method":{}}\n' > "$TMP/time.json"
printf '{"headline":{}}\n' > "$TMP/outcome.json"

# Events log: just 10 start events for session_count
EVENTS="$TMP/events.jsonl"
for i in $(seq 1 10); do
  printf '{"event":"project_boundary","ts":"2026-03-0%dT00:00:00Z","data":{"kind":"start","session_id":"s%d","terminal_id":"t1"}}\n' \
    "$((i % 9 + 1))" "$i" >> "$EVENTS"
done

# ── Call recommend::aggregate with REPLAY_HARNESS_NONZERO_ARMS=1 (nonzero sentinel) ──
export REPLAY_HARNESS_NONZERO_ARMS=1
agg=$(recommend::aggregate \
  --cost "$COST_JSON" \
  --time "$TMP/time.json" \
  --outcome "$TMP/outcome.json" \
  --events "$EVENTS" \
  --arms-dir "$ARMS" \
  --to "2026-05-29" 2>/dev/null)
unset REPLAY_HARNESS_NONZERO_ARMS

no_sig=$(printf '%s' "$agg" | jq -r '.caveats.no_significant_difference')
[ "$no_sig" = "true" ] && _pass "no_significant_difference==true" \
  || _fail "no_significant_difference==true (got: $no_sig)"

# Also verify human output contains the expected literal
human_out=$(printf '%s' "$agg" | recommend::format human 2>/dev/null)
printf '%s' "$human_out" | grep -qi 'no significant difference' \
  && _pass "human output contains 'no significant difference'" \
  || _fail "human output contains 'no significant difference' (got: $human_out)"

# Smoke: recommend.sh with events-no-sig-diff fixture exits 0
bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-no-sig-diff.jsonl" \
  --corpus /nonexistent \
  --json >/dev/null 2>&1
[ $? -eq 0 ] && _pass "recommend.sh --json exits 0 on no-sig-diff events" \
  || _fail "recommend.sh --json exits 0 on no-sig-diff events"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
