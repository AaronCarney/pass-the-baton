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
source "$REPO_ROOT/lib/cost-model-clear-only.sh"

# === Test: /clear event itself costs 0 ===
assert "/clear event has zero summary cost" "[ \"$(cost_model_clear_only::event_cost)\" = '0.000000' ]"

# === Test: caller-contract - post-/clear cache state is cold ===
assert "post-/clear cache state is cold (no preserved cache)" "[ \"$(cost_model_clear_only::post_clear_cache_state)\" = 'cold' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
