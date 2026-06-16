#!/usr/bin/env bash
# test-recommend-data-age.sh - fixture test: telemetry window crosses model release boundary.
# Fixture: events-data-age.jsonl with 7 sessions (s1..s7).
#   s3 cost_rollup ts=2025-10-01 < claude-haiku-4-5 release 2025-10-15 → dropped by --strict-recent
#   s5 cost_rollup ts=2025-09-20 < claude-haiku-4-5 release 2025-10-15 → dropped by --strict-recent
# NOTE: spec references claude-sonnet-4-5 which is not in the verified release-dates table.
#   claude-haiku-4-5 (release: 2025-10-15) is used instead - it falls in the same window.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Baseline run: session_count==7 ──
baseline=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-data-age.jsonl" \
  --corpus /nonexistent \
  --json 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && _pass "baseline exit 0" || _fail "baseline exit 0 (got $rc)"

sess_count=$(printf '%s' "$baseline" | jq -r '.session_count')
[ "$sess_count" -eq 7 ] && _pass "baseline session_count==7" \
  || _fail "baseline session_count==7 (got: $sess_count)"

# ── Human output contains crossing literal ──
human_out=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-data-age.jsonl" \
  --corpus /nonexistent \
  --human 2>/dev/null)
printf '%s' "$human_out" | grep -qi 'telemetry window crosses' \
  && _pass "human output contains 'Caveat: telemetry window crosses'" \
  || _fail "human output contains 'Caveat: telemetry window crosses' (got: $human_out)"

printf '%s' "$human_out" | grep -q 'claude-haiku-4-5' \
  && _pass "human output contains model-id 'claude-haiku-4-5'" \
  || _fail "human output contains model-id 'claude-haiku-4-5' (got: $human_out)"

# ── Strict-recent run: session_count drops to 5 (s3,s5 dropped) ──
strict=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$FX/events-data-age.jsonl" \
  --corpus /nonexistent \
  --strict-recent \
  --json 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && _pass "strict-recent exit 0" || _fail "strict-recent exit 0 (got $rc)"

strict_count=$(printf '%s' "$strict" | jq -r '.session_count')
[ "$strict_count" -eq 5 ] && _pass "strict-recent session_count==5" \
  || _fail "strict-recent session_count==5 (got: $strict_count)"

# Assert strict_count < baseline (proves --strict-recent actually filtered)
[ "$strict_count" -lt "$sess_count" ] && _pass "strict_count < baseline_count (filtering occurred)" \
  || _fail "strict_count < baseline_count (strict=$strict_count baseline=$sess_count)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
