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
source "$REPO_ROOT/lib/cost-models.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-none.sh"

# === Test: per-turn cost - sonnet-4-6 ===
# r_in=3.00, r_out=15.00
# context_in=50000, output=2000 → (50000·3.00 + 2000·15.00) / 1_000_000
# = (150000 + 30000) / 1000000 = 0.180000
cost="$(cost_model_none::turn_cost claude-sonnet-4-6 50000 2000)"
assert "per-turn cost on sonnet-4-6 (50k in, 2k out)" "[ \"$cost\" = '0.180000' ]"

# === Test: trajectory accumulator - sums turn costs from TSV stream ===
# 3 turns on sonnet-4-6:
#  turn 1: ctx=10000 out=1000  → (30000 + 15000) /1e6  = 0.045000
#  turn 2: ctx=25000 out=2000  → (75000 + 30000) /1e6  = 0.105000
#  turn 3: ctx=40000 out=1500  → (120000 + 22500)/1e6  = 0.142500
# Total = 0.292500
total="$(printf '10000\t1000\n25000\t2000\n40000\t1500\n' | cost_model_none::trajectory_cost claude-sonnet-4-6)"
assert "3-turn trajectory accumulates correctly" "[ \"$total\" = '0.292500' ]"

# === Test: empty stream → 0 ===
total="$(printf '' | cost_model_none::trajectory_cost claude-sonnet-4-6)"
assert "empty trajectory → 0" "[ \"$total\" = '0.000000' ]"

# === Test: unknown model → rc=2 ===
set +e
printf '10000\t1000\n' | cost_model_none::trajectory_cost claude-bogus >/dev/null 2>&1
rc=$?
set -e
assert "unknown model → rc=2" "[ \"$rc\" = '2' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
