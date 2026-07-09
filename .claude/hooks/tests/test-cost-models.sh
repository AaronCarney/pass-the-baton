#!/bin/bash
# Unit tests for lib/cost-models.sh - PRICE table, alias-warning lookup, cost math.
# Usage: bash .claude/hooks/tests/test-cost-models.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$REPO_ROOT/lib/cost-models.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

# shellcheck disable=SC1090
source "$LIB"

# ----- Group A: cost_models::price -----
echo "## cost_models::price"

assert "price: sonnet-4-6 base_in = 3.00" \
  "[ \"$(cost_models::price claude-sonnet-4-6 base_in)\" = '3.00' ]"
assert "price: sonnet-4-6 base_out = 15.00" \
  "[ \"$(cost_models::price claude-sonnet-4-6 base_out)\" = '15.00' ]"
assert "price: sonnet-4-6 cache_write_5m = 3.75" \
  "[ \"$(cost_models::price claude-sonnet-4-6 cache_write_5m)\" = '3.75' ]"
assert "price: sonnet-4-6 cache_write_1h = 6.00" \
  "[ \"$(cost_models::price claude-sonnet-4-6 cache_write_1h)\" = '6.00' ]"
assert "price: sonnet-4-6 cache_read = 0.30" \
  "[ \"$(cost_models::price claude-sonnet-4-6 cache_read)\" = '0.30' ]"
assert "price: haiku-4-5 cache_read = 0.10" \
  "[ \"$(cost_models::price claude-haiku-4-5 cache_read)\" = '0.10' ]"
assert "price: fable-5 base_in = 10.00" \
  "[ \"$(cost_models::price claude-fable-5 base_in)\" = '10.00' ]"
assert "price: fable-5 base_out = 50.00" \
  "[ \"$(cost_models::price claude-fable-5 base_out)\" = '50.00' ]"
assert "price: fable-5 cache_read = 1.00" \
  "[ \"$(cost_models::price claude-fable-5 cache_read)\" = '1.00' ]"
assert "min_cache_tokens: fable-5 = 2048" \
  "[ \"$(cost_models::min_cache_tokens claude-fable-5)\" = '2048' ]"

assert "price: unknown model returns exit 2" \
  "cost_models::price unknown-model base_in; [ \$? -eq 2 ]"

# ----- Group B: cost_models::min_cache_tokens -----
echo
echo "## cost_models::min_cache_tokens"

assert "min_cache_tokens: opus-4-7 = 4096" \
  "[ \"$(cost_models::min_cache_tokens claude-opus-4-7)\" = '4096' ]"
assert "min_cache_tokens: sonnet-4-6 = 2048" \
  "[ \"$(cost_models::min_cache_tokens claude-sonnet-4-6)\" = '2048' ]"
assert "min_cache_tokens: sonnet-4-5 = 1024" \
  "[ \"$(cost_models::min_cache_tokens claude-sonnet-4-5)\" = '1024' ]"

# ----- Group C: cost_models::resolve_id -----
echo
echo "## cost_models::resolve_id"

# Alias (short name) → pinned ID + stderr warning
pinned_out=$(cost_models::resolve_id claude-sonnet-4-6 2>/tmp/test-cm-stderr-alias)
stderr_alias=$(cat /tmp/test-cm-stderr-alias)
assert "resolve_id: alias returns pinned id" \
  "[ \"$pinned_out\" = 'claude-sonnet-4-6-20260101' ]"
assert "resolve_id: alias emits stderr with 'alias'" \
  "echo \"\$stderr_alias\" | grep -q 'alias'"
assert "resolve_id: alias emits stderr with 'pinned'" \
  "echo \"\$stderr_alias\" | grep -q 'pinned'"

# Pinned ID → same output, no warning
pinned_out2=$(cost_models::resolve_id claude-sonnet-4-6-20260101 2>/tmp/test-cm-stderr-pinned)
stderr_pinned=$(cat /tmp/test-cm-stderr-pinned)
assert "resolve_id: pinned id returns same pinned id" \
  "[ \"$pinned_out2\" = 'claude-sonnet-4-6-20260101' ]"
assert "resolve_id: pinned id emits no stderr warning" \
  "[ -z \"\$stderr_pinned\" ]"

# ----- Group D: cost_models::list -----
echo
echo "## cost_models::list"

list_out=$(cost_models::list)
assert "list: contains claude-opus-4-7" \
  "echo \"\$list_out\" | grep -q 'claude-opus-4-7'"
assert "list: contains claude-opus-4-6" \
  "echo \"\$list_out\" | grep -q 'claude-opus-4-6'"
assert "list: contains claude-sonnet-4-6" \
  "echo \"\$list_out\" | grep -q 'claude-sonnet-4-6'"
assert "list: contains claude-sonnet-4-5" \
  "echo \"\$list_out\" | grep -q 'claude-sonnet-4-5'"
assert "list: contains claude-haiku-4-5" \
  "echo \"\$list_out\" | grep -q 'claude-haiku-4-5'"
assert "list: contains claude-opus-4-8" \
  "echo \"\$list_out\" | grep -q 'claude-opus-4-8'"
assert "list: contains claude-fable-5" \
  "echo \"\$list_out\" | grep -q 'claude-fable-5'"
assert "list: count == ${#_CM_MODELS[@]} (canonical array length)" \
  "[ \"$(cost_models::list | wc -l | tr -d ' ')\" = \"${#_CM_MODELS[@]}\" ]"

# ----- Group E: cost_models::cost_of_turn -----
echo
echo "## cost_models::cost_of_turn"

assert "cost_of_turn: zero inputs = 0.000000" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 0 0 0 0 0)\" = '0.000000' ]"

# First-principles: 1M tokens per primitive
assert "cost_of_turn: 1M cache_read = 0.500000 (opus-4-7)" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 1000000 0 0 0 0)\" = '0.500000' ]"
assert "cost_of_turn: 1M cache_write_5m = 6.250000 (opus-4-7)" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 0 1000000 0 0 0)\" = '6.250000' ]"
assert "cost_of_turn: 1M cache_write_1h = 10.000000 (opus-4-7)" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 0 0 1000000 0 0)\" = '10.000000' ]"
assert "cost_of_turn: 1M fresh_input = 5.000000 (opus-4-7)" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 0 0 0 1000000 0)\" = '5.000000' ]"
assert "cost_of_turn: 1M output = 25.000000 (opus-4-7)" \
  "[ \"$(cost_models::cost_of_turn claude-opus-4-7 0 0 0 0 1000000)\" = '25.000000' ]"

# Mixed-primitive sanity check (derived via awk, no hardcoded total)
expected=$(awk -v cr=12000 -v cw=8000 -v fi=500 -v out=1500 \
  'BEGIN{printf "%.6f", (cr*0.30 + cw*3.75 + fi*3.00 + out*15.00)/1000000}')
actual=$(cost_models::cost_of_turn claude-sonnet-4-6 12000 8000 0 500 1500)
assert "mixed turn matches first-principles awk" "[ \"$actual\" = \"$expected\" ]"

# Geo multiplier (--geo us → ×1.10). Expected derived first-principles from
# PRICE constants (not from cost_of_turn's own output) so a uniform scale bug
# in cost_of_turn can't cancel out of both sides.
geo_cost=$(cost_models::cost_of_turn claude-sonnet-4-6 24000 2000 0 0 1500 --geo us)
expected_geo=$(awk -v cr=24000 -v cw=2000 -v out=1500 \
  'BEGIN{printf "%.6f", ((cr*0.30 + cw*3.75 + out*15.00)/1000000) * 1.10}')
assert "cost_of_turn: --geo us applies 1.10 multiplier (first-principles)" \
  "[ \"$geo_cost\" = \"$expected_geo\" ]"

# Fast mode rejected for non-Opus-4.6/4.7
fast_rc=0
cost_models::cost_of_turn claude-sonnet-4-6 0 0 0 0 0 --fast >/dev/null 2>&1 || fast_rc=$?
assert "cost_of_turn: --fast rejected for sonnet (nonzero exit)" \
  "[ \"$fast_rc\" -ne 0 ]"

# Fast mode accepted for opus-4-7 (×6.00 multiplier)
fast_actual=$(cost_models::cost_of_turn claude-opus-4-7 0 0 0 0 1500 --fast)
# 1500 tokens × $25/MTok × 6 = 1500*25/1000000*6 = 0.225000
assert "cost_of_turn: opus-4-7 --fast 1500 output = 0.225000" \
  "[ \"$fast_actual\" = '0.225000' ]"

# Unknown model exits 2
cost_models::cost_of_turn unknown-model 0 0 0 0 0 >/dev/null 2>&1
assert "cost_of_turn: unknown model exits 2" "[ $? -eq 2 ]"

# Non-numeric arg rejected (exits 2). awk would otherwise silently coerce
# 'foo' to 0 and return a false 0-cost result.
cost_models::cost_of_turn claude-opus-4-7 foo 0 0 0 0 >/dev/null 2>&1
assert "cost_of_turn: non-numeric cache_read rejected (exit 2)" "[ $? -eq 2 ]"
cost_models::cost_of_turn claude-opus-4-7 0 0 0 0 -1 >/dev/null 2>&1
assert "cost_of_turn: negative output rejected (exit 2)" "[ $? -eq 2 ]"

# Unknown --geo region rejected (exits 1). Was silently accepted as no-op.
cost_models::cost_of_turn claude-opus-4-7 0 0 0 0 0 --geo eu >/dev/null 2>&1
assert "cost_of_turn: unknown --geo region rejected (exit 1)" "[ $? -eq 1 ]"

# ----- Group F: constants -----
echo
echo "## constants"

assert "PRICING_VERIFIED_DATE is set and non-empty" \
  "[ -n \"\$PRICING_VERIFIED_DATE\" ]"
assert "PRICING_VERIFIED_DATE matches YYYY-MM-DD" \
  "echo \"\$PRICING_VERIFIED_DATE\" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'"

# ----- Group G: no network code -----
echo
echo "## no network code"

assert "no curl/wget/nc/dev-tcp in cost-models.sh" \
  "! grep -E 'curl|wget|\bnc\b|/dev/tcp' '$LIB'"

# ----- Results -----
echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
