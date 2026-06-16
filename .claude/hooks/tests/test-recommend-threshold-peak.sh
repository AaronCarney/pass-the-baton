#!/usr/bin/env bash
# test-recommend-threshold-peak.sh - fixture test: threshold sweep argmax==34.
# Uses cost-with-known-peak.json directly via --cost-json.
# The fixture has its per_threshold values engineered so threshold 34 produces
# maximum savings vs baseline 22.  Transcript files are created at /tmp/fixture/
# so replay_harness can produce nonzero arm costs (required to avoid degenerate path).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Create /tmp/fixture transcripts so replay_harness succeeds ──
mkdir -p /tmp/fixture
for i in 1 2; do
  cat > "/tmp/fixture/sess-${i}.jsonl" <<'SESS'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}
{"type":"user","message":{"content":"world"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":3000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
SESS
done

# ── Run recommend.sh ──
result=$(bash "$REPO/tools/recommend.sh" \
  --cost-json "$FX/cost-with-known-peak.json" \
  --log "$FX/events-time-nonempty.jsonl" \
  --json 2>/dev/null)
rc=$?

[ "$rc" -eq 0 ] && _pass "exit 0" || _fail "exit 0 (got $rc)"

argmax=$(printf '%s' "$result" | jq -r '.threshold_sweep.argmax // "null"')
[ "$argmax" = "34" ] && _pass "threshold_sweep.argmax==34" \
  || _fail "threshold_sweep.argmax==34 (got: $argmax)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
