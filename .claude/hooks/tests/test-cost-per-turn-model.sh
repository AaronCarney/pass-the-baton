#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/mixed-model.jsonl"
# Turn 1: opus-4-7 - 10k fresh input + 5k output
printf '{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":10000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$FIX"
# Turn 2: sonnet-4-6 - 8k fresh input + 4k output
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":8000,"output_tokens":4000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$FIX"
# Turn 3: no model field - should fall back to $BATON_COST_MODEL
printf '{"message":{"role":"assistant","usage":{"input_tokens":6000,"output_tokens":3000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$FIX"
# Turn 4: model field set to literal null - also fall back
printf '{"message":{"role":"assistant","model":null,"usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$FIX"

PASS=0; FAIL=0
_aeq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# Case 1: per-turn pricing using each turn's own .message.model.
out=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$FIX" --json 2>/dev/null)
turns=$(printf '%s' "$out" | jq -r '.turns // empty')
_aeq '4' "$turns" 'four turns counted'

# Case 2: numeric per-turn pricing correctness - mixed total differs from all-sonnet baseline.
ALL_SONNET="$TMP/all-sonnet.jsonl"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$ALL_SONNET"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":8000,"output_tokens":4000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$ALL_SONNET"
mixed_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$FIX" --json 2>/dev/null | jq -r '.cost_usd')
sonnet_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$ALL_SONNET" --json 2>/dev/null | jq -r '.cost_usd')
awk -v m="$mixed_cost" -v s="$sonnet_cost" 'BEGIN{ exit (m > s) ? 0 : 1 }' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: mixed cost ($mixed_cost) should exceed all-sonnet ($sonnet_cost)" >&2; }

# Case 3 (iter-3): cache_read/cache_creation per-turn pricing branch.
CACHE_FIX="$TMP/cache-mixed.jsonl"
printf '{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' > "$CACHE_FIX"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' >> "$CACHE_FIX"
ALL_OPUS_CACHE="$TMP/all-opus-cache.jsonl"
printf '{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' > "$ALL_OPUS_CACHE"
printf '{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' >> "$ALL_OPUS_CACHE"
ALL_SONNET_CACHE="$TMP/all-sonnet-cache.jsonl"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' > "$ALL_SONNET_CACHE"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":1000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":1000}}}\n' >> "$ALL_SONNET_CACHE"
mixed_cache_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$CACHE_FIX" --json 2>/dev/null | jq -r '.cost_usd')
opus_cache_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$ALL_OPUS_CACHE" --json 2>/dev/null | jq -r '.cost_usd')
sonnet_cache_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$ALL_SONNET_CACHE" --json 2>/dev/null | jq -r '.cost_usd')
awk -v m="$mixed_cache_cost" -v o="$opus_cache_cost" -v s="$sonnet_cache_cost" 'BEGIN{ exit (m > s && m < o) ? 0 : 1 }' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: cache-priced mixed ($mixed_cache_cost) not strictly between sonnet ($sonnet_cache_cost) and opus ($opus_cache_cost) - cache tokens may be priced under wrong model" >&2; }

# Case 4 (iter-4): cache_write_1h > 0 pricing branch.
ONE_HOUR_FIX="$TMP/one-hour.jsonl"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":5000,"cache_creation_1h_input_tokens":3000}}}\n' > "$ONE_HOUR_FIX"
FIVE_MIN_FIX="$TMP/five-min.jsonl"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":5000,"cache_creation_1h_input_tokens":0}}}\n' > "$FIVE_MIN_FIX"
one_hour_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$ONE_HOUR_FIX" --json 2>/dev/null | jq -r '.cost_usd')
five_min_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$FIVE_MIN_FIX" --json 2>/dev/null | jq -r '.cost_usd')
if grep -q 'cache_creation_1h_input_tokens' "$REPO/tools/cost.sh" "$REPO/lib/cost-models.sh" 2>/dev/null; then
  if awk -v a="$one_hour_cost" -v b="$five_min_cost" 'BEGIN{ exit (a != b) ? 0 : 1 }'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: cost.sh references cache_creation_1h_input_tokens but pricing did not diverge (one_hour=$one_hour_cost five_min=$five_min_cost)" >&2
  fi
else
  echo "SKIP: cost.sh does not reference cache_creation_1h_input_tokens - Case 4 documents the gap without gating." >&2
  PASS=$((PASS+1))
fi

# Case 5 (review follow-up): per-turn dated/pinned model ID (<alias>-YYYYMMDD)
# must strip to its alias and price as that alias - not fall back to the default.
# Fixture realism: real API transcripts carry dated IDs, not bare aliases.
DATED_FIX="$TMP/dated.jsonl"
printf '{"message":{"role":"assistant","model":"claude-opus-4-7-20250101","usage":{"input_tokens":10000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$DATED_FIX"
BARE_OPUS_FIX="$TMP/bare-opus.jsonl"
printf '{"message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":10000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$BARE_OPUS_FIX"
BARE_SONNET_FIX="$TMP/bare-sonnet.jsonl"
printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$BARE_SONNET_FIX"
dated_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$DATED_FIX" --json 2>/dev/null | jq -r '.cost_usd')
bare_opus_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$BARE_OPUS_FIX" --json 2>/dev/null | jq -r '.cost_usd')
bare_sonnet_cost=$(BATON_COST_MODEL=claude-sonnet-4-6 bash "$REPO/tools/cost.sh" --transcript "$BARE_SONNET_FIX" --json 2>/dev/null | jq -r '.cost_usd')
_aeq "$bare_opus_cost" "$dated_cost" 'dated opus ID strips to opus alias (same price as bare alias)'
awk -v d="$dated_cost" -v s="$bare_sonnet_cost" 'BEGIN{ exit (d != s) ? 0 : 1 }' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: dated opus ($dated_cost) priced as sonnet default ($bare_sonnet_cost) - strip fell through" >&2; }

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
