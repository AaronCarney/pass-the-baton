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
source "$REPO_ROOT/lib/cost-model-automemory.sh"

# === Test: first-session prefix write (cache_write_5m) - sonnet-4-6 ===
# sonnet-4-6: r_cw_5m = 3.75 USD/MTok
# automemory_tokens=5000 → cost = 5000·3.75 / 1_000_000 = 0.018750
cost="$(cost_model_automemory::event_cost claude-sonnet-4-6 5000 first)"
assert "first-session auto-memory write on sonnet-4-6 (5k tokens)" "[ \"$cost\" = '0.018750' ]"

# === Test: within-ttl auto-memory read - sonnet-4-6 ===
# r_cr = 0.30 → 5000·0.30 / 1_000_000 = 0.001500
cost="$(cost_model_automemory::event_cost claude-sonnet-4-6 5000 within-ttl)"
assert "within-TTL auto-memory read" "[ \"$cost\" = '0.001500' ]"

# === Test: post-compact survives - zero cost ===
cost="$(cost_model_automemory::event_cost claude-sonnet-4-6 5000 post-compact)"
assert "post-compact auto-memory pays 0 (survives /compact)" "[ \"$cost\" = '0.000000' ]"

# === Test: invalid model → rc=2 ===
set +e
cost_model_automemory::event_cost claude-bogus 5000 first >/dev/null 2>&1
rc=$?
set -e
assert "unknown model → rc=2" "[ \"$rc\" = '2' ]"

# === Test: invalid mode → rc=1 ===
set +e
cost_model_automemory::event_cost claude-sonnet-4-6 5000 bogus >/dev/null 2>&1
rc=$?
set -e
assert "invalid mode → rc=1" "[ \"$rc\" = '1' ]"

# === Test: non-integer tokens → rc=1 ===
set +e
cost_model_automemory::event_cost claude-sonnet-4-6 not-a-number first >/dev/null 2>&1
rc=$?
set -e
assert "non-integer tokens → rc=1" "[ \"$rc\" = '1' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
