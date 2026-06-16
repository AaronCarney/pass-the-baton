#!/usr/bin/env bash
# Test harness for lib/cost-model-compact.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-models.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-compact.sh"

# === Test: warm-cache compact cost - sonnet-4-6 ===
# Sys=20000, P=100000 → S=clamp(10000, 2000, 20000)=10000.
# Per L0: (Sys+P)·r_cr + 1100·r_in + S·r_out + S·r_cw_5m
# sonnet-4-6: r_cr=0.30, r_in=3.00, r_out=15.00, r_cw_5m=3.75 (per MTok)
# Warm = (120000)·0.30 + 1100·3.00 + 10000·15.00 + 10000·3.75 = 36000 + 3300 + 150000 + 37500 = 226800 per MTok-units → 0.226800 USD
cost="$(cost_model_compact::event_cost claude-sonnet-4-6 100000 warm)"
assert "warm /compact on sonnet-4-6 with P=100k" "[ \"$cost\" = '0.226800' ]"

# === Test: cold-cache compact cost - sonnet-4-6 ===
# Cold = (Sys+P)·r_in + 1100·r_in + S·r_out + S·r_cw_5m
# = 120000·3.00 + 1100·3.00 + 10000·15.00 + 10000·3.75
# = 360000 + 3300 + 150000 + 37500 = 550800 per MTok-units → 0.550800 USD
cost="$(cost_model_compact::event_cost claude-sonnet-4-6 100000 cold)"
assert "cold /compact on sonnet-4-6 with P=100k" "[ \"$cost\" = '0.550800' ]"

# === Test: summary_tokens clamp ===
assert "S floor at 2000 when 0.10·P=1000 < floor" "[ \"$(cost_model_compact::summary_tokens 10000)\" = '2000' ]"
assert "S ceiling at 20000 when 0.10·P=50000 > ceiling" "[ \"$(cost_model_compact::summary_tokens 500000)\" = '20000' ]"
assert "S = 0.10·P in mid-range" "[ \"$(cost_model_compact::summary_tokens 50000)\" = '5000' ]"

# === Test: invalid model returns rc=2 ===
set +e
cost_model_compact::event_cost claude-bogus 100000 warm >/dev/null 2>&1
rc=$?
set -e
assert "unknown model → rc=2 (state via cost_models::price)" "[ \"$rc\" = '2' ]"

# === Test: invalid cache_state returns rc=1 ===
set +e
cost_model_compact::event_cost claude-sonnet-4-6 100000 lukewarm >/dev/null 2>&1
rc=$?
set -e
assert "invalid cache_state → rc=1 (arg)" "[ \"$rc\" = '1' ]"

# === Test: non-integer P returns rc=1 ===
set +e
cost_model_compact::event_cost claude-sonnet-4-6 not-a-number warm >/dev/null 2>&1
rc=$?
set -e
assert "non-integer P → rc=1 (arg)" "[ \"$rc\" = '1' ]"

# === Test: negative P returns rc=1 ===
set +e
cost_model_compact::event_cost claude-sonnet-4-6 -100 warm >/dev/null 2>&1
rc=$?
set -e
assert "negative P → rc=1 (arg)" "[ \"$rc\" = '1' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
