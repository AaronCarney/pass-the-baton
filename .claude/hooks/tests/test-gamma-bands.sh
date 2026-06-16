#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

source "$REPO_ROOT/lib/aggregator-v2.sh"
source "$REPO_ROOT/lib/gamma-bands.sh"

# --- Cycle 1: single-arm compute ---
rc=0; out=$(gamma_bands::compute '{"none":0.500000}') || rc=$?
assert 'compute rc=0' "[ $rc -eq 0 ]"
assert 'output is JSON' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'output has .none.cost == 0.500000' "printf '%s' \"\$out\" | jq -e '.none.cost == 0.5' >/dev/null"
assert 'output has .none.gamma_low == 1.5' "printf '%s' \"\$out\" | jq -e '.none.gamma_low == 1.5' >/dev/null"
assert 'output has .none.gamma_high == 3.0' "printf '%s' \"\$out\" | jq -e '.none.gamma_high == 3.0' >/dev/null"
assert '.none.cost_upper == 1.5' "printf '%s' \"\$out\" | jq -e '.none.cost_upper == 1.5' >/dev/null"
assert '.none.cost_lower ≈ 0.166667' "printf '%s' \"\$out\" | jq -e '(.none.cost_lower * 1000000 | round) == 166667' >/dev/null"

# --- Step 4: multi-arm input ---
out=$(gamma_bands::compute '{"none":0.500000,"auto-memory":0.314250,"clear-only":0.500000,"compact":0.403800}')
assert 'multi-arm: 4 arms present' "printf '%s' \"\$out\" | jq -e '(. | keys | length) == 4' >/dev/null"
assert 'auto-memory cost_upper == 0.94275' "printf '%s' \"\$out\" | jq -e '.\"auto-memory\".cost_upper == 0.94275' >/dev/null"
assert 'compact cost_lower ≈ 0.134600' "printf '%s' \"\$out\" | jq -e '(.compact.cost_lower * 1000000 | round) == 134600' >/dev/null"

# --- All 4 Γ bands present per arm (L0 §B11 sweep Γ ∈ {1.5, 2.0, 2.5, 3.0}) ---
out=$(gamma_bands::compute '{"none":0.500000,"auto-memory":0.314250}')
for arm in none 'auto-memory'; do
  assert "$arm has band_at_1_5"                "printf '%s' \"\$out\" | jq -e '.\"$arm\".band_at_1_5 != null' >/dev/null"
  assert "$arm has band_at_2_0"                "printf '%s' \"\$out\" | jq -e '.\"$arm\".band_at_2_0 != null' >/dev/null"
  assert "$arm has band_at_2_5"                "printf '%s' \"\$out\" | jq -e '.\"$arm\".band_at_2_5 != null' >/dev/null"
  assert "$arm has band_at_3_0"                "printf '%s' \"\$out\" | jq -e '.\"$arm\".band_at_3_0 != null' >/dev/null"
  assert "$arm band_at_1_5 has cost_lower/upper" "printf '%s' \"\$out\" | jq -e '.\"$arm\".band_at_1_5.cost_lower != null and .\"$arm\".band_at_1_5.cost_upper != null' >/dev/null"
done
# Math: cost=0.500000
#   band_at_1_5: lower=0.333333, upper=0.750000
#   band_at_2_0: lower=0.250000, upper=1.000000
#   band_at_2_5: lower=0.200000, upper=1.250000
#   band_at_3_0: lower=0.166667, upper=1.500000
assert 'none.band_at_1_5.cost_upper == 0.75'   "printf '%s' \"\$out\" | jq -e '.none.band_at_1_5.cost_upper == 0.75' >/dev/null"
assert 'none.band_at_2_0.cost_upper == 1.0'    "printf '%s' \"\$out\" | jq -e '.none.band_at_2_0.cost_upper == 1.0' >/dev/null"
assert 'none.band_at_2_0.cost_lower == 0.25'   "printf '%s' \"\$out\" | jq -e '.none.band_at_2_0.cost_lower == 0.25' >/dev/null"
assert 'none.band_at_2_5.cost_upper == 1.25'   "printf '%s' \"\$out\" | jq -e '.none.band_at_2_5.cost_upper == 1.25' >/dev/null"
assert 'none.band_at_2_5.cost_lower == 0.2'    "printf '%s' \"\$out\" | jq -e '.none.band_at_2_5.cost_lower == 0.2' >/dev/null"
assert 'none.band_at_3_0.cost_upper == 1.5'    "printf '%s' \"\$out\" | jq -e '.none.band_at_3_0.cost_upper == 1.5' >/dev/null"
assert 'none.band_at_3_0.cost_lower ≈ 0.166667' "printf '%s' \"\$out\" | jq -e '(.none.band_at_3_0.cost_lower * 1000000 | round) == 166667' >/dev/null"

# --- Cycle 2: caveat wrapper ---
out=$(gamma_bands::caveat)
assert 'caveat mentions marginal-sensitivity-model' "printf '%s' \"\$out\" | grep -q 'marginal-sensitivity-model'"
assert 'caveat mentions LLM-agent setting' "printf '%s' \"\$out\" | grep -q 'LLM-agent setting'"
assert 'caveat ends with ...is not.' "printf '%s' \"\$out\" | grep -q 'bounded estimator is the methodologically defensible answer; a single point estimate is not'"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
fi
[ $FAIL -eq 0 ] || exit 1
