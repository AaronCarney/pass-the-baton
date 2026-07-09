#!/bin/bash
# Regression test for the unpriced-main-path-turn honesty feature in tools/cost.sh.
# A genuinely-unknown per-turn .message.model must surface in the JSON field
# fallback_priced_models; a known model must leave it empty. This guards against
# the _FALLBACK_PRICED subshell-mutation regression (the tracking must run in the
# parent loop, not inside the $(...) alias-derivation function).
# Usage: bash .claude/hooks/tests/test-cost-fallback-priced.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COST_SH="$REPO_ROOT/tools/cost.sh"
MODELS="$REPO_ROOT/lib/cost-models.sh"

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

[[ -f "$MODELS" ]] || { echo "FATAL: cost-models.sh not at $MODELS"; exit 2; }
[[ -f "$COST_SH" ]] || { echo "FATAL: cost.sh not at $COST_SH"; exit 2; }

UNKNOWN_TX="$(mktemp)"
KNOWN_TX="$(mktemp)"
trap 'rm -f "$UNKNOWN_TX" "$KNOWN_TX"' EXIT

printf '%s\n' \
  '{"type":"assistant","message":{"model":"bogus-model-xyz","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$UNKNOWN_TX"

printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$KNOWN_TX"

run_cost() {
  BATON_COST_MODELS_PATH="$MODELS" bash "$COST_SH" --transcript "$1" --json 2>/dev/null
}

echo "## unknown per-turn model -> fallback_priced_models populated"
# shellcheck disable=SC2034  # used inside the eval'd assert conditions below
UNKNOWN_JSON="$(run_cost "$UNKNOWN_TX")"
assert "unknown: fallback_priced_models length >= 1" \
  "[ \"\$(printf '%s' \"\$UNKNOWN_JSON\" | jq -r '.fallback_priced_models | length')\" -ge 1 ]"
assert "unknown: fallback_priced_models contains bogus-model-xyz" \
  "printf '%s' \"\$UNKNOWN_JSON\" | jq -e '.fallback_priced_models | index(\"bogus-model-xyz\")' >/dev/null"

echo
echo "## known per-turn model -> fallback_priced_models empty"
# shellcheck disable=SC2034  # used inside the eval'd assert condition below
KNOWN_JSON="$(run_cost "$KNOWN_TX")"
assert "known: fallback_priced_models length == 0" \
  "[ \"\$(printf '%s' \"\$KNOWN_JSON\" | jq -r '.fallback_priced_models | length')\" = '0' ]"

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
