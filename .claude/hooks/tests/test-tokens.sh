#!/bin/bash
# Unit tests for lib/tokens.sh - byte→token estimator + ratios file integration.
# Usage: bash .claude/hooks/tests/test-tokens.sh

export LC_ALL=C
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
LIB="$REPO_ROOT/lib/tokens.sh"

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

# ----- Group A: basic estimates (no model / sonnet) -----
echo "## basic estimates"

tokens::load_ratios  # no-op without ratios file

result=$(tokens::estimate 320 prose)
assert "estimate: 320 prose → 80" "[ '$result' = '80' ]"

result=$(tokens::estimate 320 json)
assert "estimate: 320 json → 119 (half-up)" "[ '$result' = '119' ]"

result=$(tokens::estimate 320 code claude-sonnet-4-6)
assert "estimate: 320 code sonnet → 100" "[ '$result' = '100' ]"

result=$(tokens::estimate 0 code)
assert "estimate: 0 bytes → 0" "[ '$result' = '0' ]"

result=$(tokens::estimate 1000 base64 claude-haiku-4-5)
assert "estimate: 1000 base64 haiku → 500" "[ '$result' = '500' ]"

# ----- Group B: Opus 4.7 multipliers -----
echo
echo "## opus 4.7 multipliers"

result=$(tokens::estimate 320 code claude-opus-4-7)
assert "estimate: 320 code opus-4-7 → 120 (1.20x)" "[ '$result' = '120' ]"

result=$(tokens::estimate 320 prose claude-opus-4-7)
assert "estimate: 320 prose opus-4-7 → 88 (1.10x)" "[ '$result' = '88' ]"

# ----- Group C: content_type_for_path -----
echo
echo "## content_type_for_path"

result=$(tokens::content_type_for_path foo.json)
assert "content_type_for_path: .json → json" "[ '$result' = 'json' ]"

result=$(tokens::content_type_for_path script.sh)
assert "content_type_for_path: .sh → code" "[ '$result' = 'code' ]"

result=$(tokens::content_type_for_path README.md)
assert "content_type_for_path: .md → prose" "[ '$result' = 'prose' ]"

result=$(tokens::content_type_for_path patch.diff)
assert "content_type_for_path: .diff → diff" "[ '$result' = 'diff' ]"

result=$(tokens::content_type_for_path unknown.bin)
assert "content_type_for_path: unknown → code (default)" "[ '$result' = 'code' ]"

# ----- Group D: ratios file override -----
echo
echo "## ratios file override"

RATIOS_FILE=$(mktemp /tmp/ratios-test-XXXXXX.sh)
echo 'BYTES_PER_TOKEN_PROSE=5.0' > "$RATIOS_FILE"

# Override in a subshell, capture result to a temp file to avoid pipe subshell isolation.
RATIOS_TMPOUT=$(mktemp /tmp/ratios-result-XXXXXX)
(
  # shellcheck disable=SC1090
  source "$LIB"
  export BATON_TOKEN_RATIOS="$RATIOS_FILE"
  tokens::load_ratios
  tokens::estimate 500 prose
) > "$RATIOS_TMPOUT"
ratios_result=$(cat "$RATIOS_TMPOUT")
rm -f "$RATIOS_TMPOUT" "$RATIOS_FILE"

assert "ratios override: BYTES_PER_TOKEN_PROSE=5.0 → 500/5.0=100" "[ '$ratios_result' = '100' ]"

# load_ratios is idempotent - calling twice must give same result.
RATIOS_FILE2=$(mktemp /tmp/ratios-test2-XXXXXX.sh)
echo 'BYTES_PER_TOKEN_JSON=4.0' > "$RATIOS_FILE2"
RATIOS_TMPOUT2=$(mktemp /tmp/ratios-result2-XXXXXX)
(
  # shellcheck disable=SC1090
  source "$LIB"
  export BATON_TOKEN_RATIOS="$RATIOS_FILE2"
  tokens::load_ratios
  tokens::load_ratios  # second call - idempotent
  tokens::estimate 400 json
) > "$RATIOS_TMPOUT2"
ratios_result2=$(cat "$RATIOS_TMPOUT2")
rm -f "$RATIOS_TMPOUT2" "$RATIOS_FILE2"

assert "ratios override: BYTES_PER_TOKEN_JSON=4.0 idempotent → 400/4.0=100" "[ '$ratios_result2' = '100' ]"

# ----- Group E: no network calls -----
echo
echo "## no network calls"

assert "no network: lib/tokens.sh has no curl/wget/nc/tcp" \
  "! grep -E 'curl|wget|\bnc\b|/dev/tcp' '$LIB'"

# ----- Group F: estimate_file read-failure (FIX-3 regression) -----
echo
echo "## estimate_file read-failure returns 2 (FIX-3)"

# tokens.sh is sourced into this runner. A read failure must `return 2`,
# never `exit 2` - an exit would kill the whole test process. Run in a
# subshell whose post-call sentinel only prints if control actually
# returned from estimate_file (an exit would skip the printf).
unreadable="$REPO_ROOT/.no-such-file-$$"
rm -f "$unreadable"
ef_sentinel=$( (
  tokens::estimate_file "$unreadable" prose >/dev/null 2>&1
  printf 'RET:%s' "$?"
) )
assert "estimate_file: unreadable path returns 2, control not exited" \
  "[ '$ef_sentinel' = 'RET:2' ]"

# ----- Summary -----
echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
