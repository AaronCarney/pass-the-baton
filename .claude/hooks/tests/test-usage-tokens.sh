#!/bin/bash
# Tests for .claude/hooks/lib/usage-tokens.sh (E20-CC16).
# Verifies usage_tokens::extract reproduces the five-field token breakdown
# with the ephemeral-split-else-flat precedence, byte-identical to the jq
# previously inlined in post-tool-batch.sh.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/usage-tokens.sh
source "$HOOKS_DIR/lib/usage-tokens.sh"

PASSED=0
FAILED=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASSED=$((PASSED+1)); echo "  PASS  $name"
  else
    FAILED=$((FAILED+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# Parse the tab-separated contract into the five named vars.
parse_extract() {
  local usage="$1"
  IFS=$'\t' read -r cache_read cache_write_5m cache_write_1h fresh_input output \
    < <(usage_tokens::extract "$usage")
}

echo "## .claude/hooks/lib/usage-tokens.sh"

# --- (a) ephemeral split present: flat cache_creation IGNORED -----------------
parse_extract '{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":3,"cache_creation_input_tokens":999,"cache_read_input_tokens":5,"input_tokens":7,"output_tokens":2}'
assert "(a) cache_read=5"       "[ '$cache_read' = '5' ]"
assert "(a) cache_write_5m=10"  "[ '$cache_write_5m' = '10' ]"
assert "(a) cache_write_1h=3"   "[ '$cache_write_1h' = '3' ]"
assert "(a) fresh_input=7"      "[ '$fresh_input' = '7' ]"
assert "(a) output=2"           "[ '$output' = '2' ]"

# --- (b) no ephemeral split: flat cache_creation is the 5m write -------------
parse_extract '{"cache_creation_input_tokens":42,"cache_read_input_tokens":1,"input_tokens":4,"output_tokens":9}'
assert "(b) cache_read=1"       "[ '$cache_read' = '1' ]"
assert "(b) cache_write_5m=42"  "[ '$cache_write_5m' = '42' ]"
assert "(b) cache_write_1h=0"   "[ '$cache_write_1h' = '0' ]"
assert "(b) fresh_input=4"      "[ '$fresh_input' = '4' ]"
assert "(b) output=9"           "[ '$output' = '9' ]"

# --- (c) empty usage: all five default to 0 ----------------------------------
parse_extract '{}'
assert "(c) cache_read=0"       "[ '$cache_read' = '0' ]"
assert "(c) cache_write_5m=0"   "[ '$cache_write_5m' = '0' ]"
assert "(c) cache_write_1h=0"   "[ '$cache_write_1h' = '0' ]"
assert "(c) fresh_input=0"      "[ '$fresh_input' = '0' ]"
assert "(c) output=0"           "[ '$output' = '0' ]"

echo
echo "  $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
