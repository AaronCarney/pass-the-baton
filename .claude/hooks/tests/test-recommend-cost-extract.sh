#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/lib/recommend-cost-extract.sh"
FIXTURE="$SCRIPT_DIR/fixtures/recommend/cost-real.json"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

# shellcheck source=/dev/null
source "$LIB"

# --- Basic fixture tests (cost-real.json) ---

winner=$(recommend_cost::winner "$FIXTURE")
assert 'winner is non-empty string' '[ -n "$winner" ]'
assert 'winner is valid arm' '[[ "$winner" =~ ^(compact|auto-memory|clear-only|none)$ ]]'

# Verify winner is truly min usd_total among clean subset
min_arm=$(jq -r '[.per_arm_per_subset[]? | select(.subset=="clean")] | min_by(.usd_total | tonumber) | .arm' "$FIXTURE")
assert 'winner matches jq min_by clean' '[ "$winner" = "$min_arm" ]'

per_method=$(recommend_cost::per_method "$FIXTURE")
assert 'per_method parses as JSON' 'jq -e . >/dev/null 2>&1 <<< "$per_method"'
assert 'per_method has compact key' 'jq -e "has(\"compact\")" >/dev/null <<< "$per_method"'
assert 'per_method.compact has usd_total' 'jq -e ".compact | has(\"usd_total\")" >/dev/null <<< "$per_method"'
assert 'per_method.compact has session_count' 'jq -e ".compact | has(\"session_count\")" >/dev/null <<< "$per_method"'
assert 'per_method has all 4 arms' 'jq -e "keys | length == 4" >/dev/null <<< "$per_method"'

typical=$(recommend_cost::typical_best "$FIXTURE")
assert 'typical_best parses as JSON' 'jq -e . >/dev/null 2>&1 <<< "$typical"'
assert 'typical_best has median key' 'jq -e "has(\"median\")" >/dev/null <<< "$typical"'
assert 'typical_best has mode key' 'jq -e "has(\"mode\")" >/dev/null <<< "$typical"'

aggregates=$(recommend_cost::aggregates "$FIXTURE")
assert 'aggregates parses as JSON' 'jq -e . >/dev/null 2>&1 <<< "$aggregates"'
assert 'aggregates has key 22' 'jq -e "has(\"22\")" >/dev/null <<< "$aggregates"'
assert 'aggregates["22"] has .median' 'jq -e ".\"22\" | has(\"median\")" >/dev/null <<< "$aggregates"'

# --- Empty fixture tests (no crash) ---
EMPTY_TMP="$(mktemp)"
trap 'rm -f "$EMPTY_TMP"' EXIT
printf '{"per_arm_per_subset":[],"transcripts":[],"typical_best":{"median":null,"mode":null},"aggregates":{}}' > "$EMPTY_TMP"

empty_winner=$(recommend_cost::winner "$EMPTY_TMP")
assert 'empty: winner is null' '[ "$empty_winner" = "null" ]'

empty_per_method=$(recommend_cost::per_method "$EMPTY_TMP")
assert 'empty: per_method is {}' 'jq -e ". == {}" >/dev/null <<< "$empty_per_method"'

empty_typical=$(recommend_cost::typical_best "$EMPTY_TMP")
assert 'empty: typical_best.median is null' 'jq -e ".median == null" >/dev/null <<< "$empty_typical"'

empty_agg=$(recommend_cost::aggregates "$EMPTY_TMP")
assert 'empty: aggregates is {}' 'jq -e ". == {}" >/dev/null <<< "$empty_agg"'

# --- Producer-contract test ---
CORPUS_TMP="$(mktemp -d)"
trap 'rm -rf "$CORPUS_TMP"; rm -f "$EMPTY_TMP"' EXIT
mkdir -p "$CORPUS_TMP/projects/ws-A" "$CORPUS_TMP/projects/ws-B"
export BATON_PROGRESS_DIR="$CORPUS_TMP/no-prog" BATON_ARCHIVE_DIR="$CORPUS_TMP/no-arch"
cat > "$CORPUS_TMP/projects/ws-A/sess-1.jsonl" << 'JSONL'
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":5000,"cache_creation_input_tokens":3000}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":15000,"cache_creation_input_tokens":0}}}
JSONL
cat > "$CORPUS_TMP/projects/ws-B/sess-2.jsonl" << 'JSONL'
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":8000,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":20000,"output_tokens":1500,"cache_read_input_tokens":3000,"cache_creation_input_tokens":2000}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":35000,"output_tokens":1200,"cache_read_input_tokens":12000,"cache_creation_input_tokens":0}}}
JSONL

LIVE_JSON="$(mktemp)"
bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus "$CORPUS_TMP/projects" --json 2>/dev/null > "$LIVE_JSON"

live_winner=$(recommend_cost::winner "$LIVE_JSON")
assert 'contract: winner is non-null arm' '[[ "$live_winner" =~ ^(compact|auto-memory|clear-only|none)$ ]]'

live_agg=$(recommend_cost::aggregates "$LIVE_JSON")
# Producer emits exactly these threshold keys per c-020: 10,12,14,...,50 step 2 + never
EXPECTED_KEYS='["10","12","14","16","18","20","22","24","26","28","30","32","34","36","38","40","42","44","46","48","50","never"]'
actual_keys=$(jq -c '[keys[]] | sort' <<< "$live_agg")
assert 'contract: aggregates keys match producer THRESHOLDS (c-020)' '[ "$actual_keys" = "$EXPECTED_KEYS" ]'

# Each key has a numeric .median sub-field
assert 'contract: aggregates["22"].median is numeric' 'jq -e ".\"22\".median | type == \"number\"" >/dev/null <<< "$live_agg"'
assert 'contract: no key "23" in aggregates (c-021)' '! jq -e "has(\"23\")" >/dev/null <<< "$live_agg"'

rm -f "$LIVE_JSON"

echo "PRODUCER_CONTRACT_COST_OK"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ ${#FAILED[@]} -gt 0 ] && printf '  FAILED: %s\n' "${FAILED[@]}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
