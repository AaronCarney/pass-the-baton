#!/usr/bin/env bash
# test-recommend-threshold-sweep.sh - TDD tests for lib/recommend-threshold-sweep.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/lib/recommend-threshold-sweep.sh"
FIXTURES="$SCRIPT_DIR/fixtures/recommend"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

# shellcheck source=/dev/null
source "$LIB"

# ── (a) argmax == 34 on known-peak fixture ──────────────────────────────────
out_peak=$(SEED=42 recommend_threshold::sweep "$FIXTURES/cost-with-known-peak.json")
assert 'known-peak: output is valid JSON' \
  "printf '%s' \"\$out_peak\" | jq -e . >/dev/null 2>&1"
assert 'known-peak: argmax == 34' \
  "printf '%s' \"\$out_peak\" | jq -e '.argmax == 34' >/dev/null 2>&1"

# ── (b) .candidates enumerates producer-emitted numeric keys (21 entries) ──
assert 'known-peak: candidates is array' \
  "printf '%s' \"\$out_peak\" | jq -e '.candidates | type == \"array\"' >/dev/null 2>&1"
assert 'known-peak: candidates has 21 entries' \
  "printf '%s' \"\$out_peak\" | jq -e '.candidates | length == 21' >/dev/null 2>&1"
assert 'known-peak: each candidate has threshold, projected_median, savings_vs_22' \
  "printf '%s' \"\$out_peak\" | jq -e '.candidates | all(has(\"threshold\") and has(\"projected_median\") and has(\"savings_vs_22\"))' >/dev/null 2>&1"

# ── (c) savings_vs_22_at_argmax is positive ─────────────────────────────────
assert 'known-peak: savings_vs_22_at_argmax > 0' \
  "printf '%s' \"\$out_peak\" | jq -e '.savings_vs_22_at_argmax > 0' >/dev/null 2>&1"

# ── (d) .ci has lower/upper fields ──────────────────────────────────────────
assert 'known-peak: ci has lower field' \
  "printf '%s' \"\$out_peak\" | jq -e '.ci | has(\"lower\")' >/dev/null 2>&1"
assert 'known-peak: ci has upper field' \
  "printf '%s' \"\$out_peak\" | jq -e '.ci | has(\"upper\")' >/dev/null 2>&1"

# ── (e) empty corpus: argmax=null, empty candidates, no crash ───────────────
EMPTY_TMP=$(mktemp /tmp/cost-empty-XXXXXX.json)
printf '{"aggregates":{},"transcripts":[]}' > "$EMPTY_TMP"
out_empty=$(SEED=42 recommend_threshold::sweep "$EMPTY_TMP" 2>/dev/null)
rm -f "$EMPTY_TMP"
assert 'empty: output is valid JSON' \
  "printf '%s' \"\$out_empty\" | jq -e . >/dev/null 2>&1"
assert 'empty: argmax == null' \
  "printf '%s' \"\$out_empty\" | jq -e '.argmax == null' >/dev/null 2>&1"
assert 'empty: candidates is empty array' \
  "printf '%s' \"\$out_empty\" | jq -e '.candidates | length == 0' >/dev/null 2>&1"

# ── (f) tie-break on flat fixture: argmax == 10 EXACTLY, savings == 0 ───────
out_flat=$(SEED=42 recommend_threshold::sweep "$FIXTURES/cost-flat.json")
assert 'flat: argmax == 10 (tie-break: smallest T)' \
  "printf '%s' \"\$out_flat\" | jq -e '.argmax == 10' >/dev/null 2>&1"
assert 'flat: savings_vs_22_at_argmax == 0' \
  "printf '%s' \"\$out_flat\" | jq -e '.savings_vs_22_at_argmax == 0' >/dev/null 2>&1"

# ── (g) producer-key enumeration: exactly [10,12,...,50] no 5/15/23/35/45 ──
expected='[10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50]'
actual_keys=$(printf '%s' "$out_peak" | jq -c '[.candidates[].threshold]')
assert 'known-peak: candidate thresholds match producer keys exactly' \
  "[ \"\$actual_keys\" = '$expected' ]"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed: ${FAILED[*]}"
  exit 1
fi
exit 0
