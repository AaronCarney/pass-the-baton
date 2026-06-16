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

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/aggregator-v2.sh"

# === Test: per_arm_per_subset_block - happy path ===
block="$(aggregator_v2::per_arm_per_subset_block compact clean 1.234500 42)"
expected='{"arm":"compact","subset":"clean","usd_total":"1.234500","session_count":42}'
assert "per_arm_per_subset_block compact/clean" "[ \"$block\" = \"$expected\" ]"

block="$(aggregator_v2::per_arm_per_subset_block none fired 0.000000 0)"
expected='{"arm":"none","subset":"fired","usd_total":"0.000000","session_count":0}'
assert "per_arm_per_subset_block none/fired with 0 sessions" "[ \"$block\" = \"$expected\" ]"

# === Test: rc=1 on invalid arm ===
set +e
aggregator_v2::per_arm_per_subset_block bogus clean 1.0 1 >/dev/null 2>&1
rc=$?
set -e
assert "invalid arm → rc=1" "[ \"$rc\" = '1' ]"

# === Test: rc=1 on invalid subset ===
set +e
aggregator_v2::per_arm_per_subset_block compact lukewarm 1.0 1 >/dev/null 2>&1
rc=$?
set -e
assert "invalid subset → rc=1" "[ \"$rc\" = '1' ]"

# === Test: rc=1 on non-integer session_count ===
set +e
aggregator_v2::per_arm_per_subset_block compact clean 1.0 not-a-num >/dev/null 2>&1
rc=$?
set -e
assert "non-integer session_count → rc=1" "[ \"$rc\" = '1' ]"

# === Test: cc12_caveat - verbatim B11 string ===
cav="$(aggregator_v2::cc12_caveat)"
# Verify it's valid JSON string (not bare text)
# Use printf | grep to avoid eval quoting issues with "$cav" containing literal "
assert "cc12_caveat is JSON-string-quoted" "printf '%s' \"\$cav\" | grep -qP '^\".+\"$'"
# Spot-check the content includes the B11 key phrase
assert "cc12_caveat mentions marginal-sensitivity-model" "printf '%s' \"\$cav\" | grep -q 'marginal-sensitivity-model'"
assert "cc12_caveat mentions observational epidemiology" "printf '%s' \"\$cav\" | grep -q 'observational.epidemiology'"

# === Test: subset_size_warning - 0.5 (above threshold) → null ===
warn="$(aggregator_v2::subset_size_warning 0.5)"
assert "subset_size_warning(0.5) = null" "[ \"$warn\" = 'null' ]"

# === Test: subset_size_warning - 0.3 exactly (at threshold) → null ===
warn="$(aggregator_v2::subset_size_warning 0.3)"
assert "subset_size_warning(0.3) = null (>= threshold)" "[ \"$warn\" = 'null' ]"

# === Test: subset_size_warning - 0.25 (below threshold) → quoted string ===
warn="$(aggregator_v2::subset_size_warning 0.25)"
assert "subset_size_warning(0.25) is quoted string" "printf '%s' \"\$warn\" | grep -qP '^\".+\"$'"
assert "subset_size_warning(0.25) mentions 30%" "printf '%s' \"\$warn\" | grep -q '30'"
assert "subset_size_warning(0.25) mentions B11" "printf '%s' \"\$warn\" | grep -q 'B11'"

# === Test: rc=1 on out-of-range ===
set +e
aggregator_v2::subset_size_warning 1.5 >/dev/null 2>&1
rc=$?
set -e
assert "subset_size_warning(1.5) → rc=1" "[ \"$rc\" = '1' ]"

set +e
aggregator_v2::subset_size_warning -0.1 >/dev/null 2>&1
rc=$?
set -e
assert "subset_size_warning(-0.1) → rc=1" "[ \"$rc\" = '1' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
