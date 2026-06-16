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
source "$REPO_ROOT/lib/transcript.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/subset-stratify.sh"

FIX="$(mktemp -d)"

# Fixture: 2 turns, no compact boundary
CLEAN="$FIX/clean.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > "$CLEAN"

# Fixture: 2 turns, ONE compact boundary after turn 1
FIRED="$FIX/fired.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":10000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > "$FIRED"

# === Test: compaction_fired on clean fixture = 0 ===
flag="$(subset_stratify::compaction_fired "$CLEAN")"
assert "compaction_fired on clean = 0" "[ \"$flag\" = '0' ]"

# === Test: compaction_fired on fired fixture = 1 ===
flag="$(subset_stratify::compaction_fired "$FIRED")"
assert "compaction_fired on fired = 1" "[ \"$flag\" = '1' ]"

# === Test: missing transcript → rc=1 ===
set +e
subset_stratify::compaction_fired /nonexistent/path.jsonl >/dev/null 2>&1
rc=$?
set -e
assert "compaction_fired missing transcript → rc=1" "[ \"$rc\" = '1' ]"

# Fixture: /clear used
CLEAR_FIX="$FIX/clear-used.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"user","message":{"content":"/clear"}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > "$CLEAR_FIX"

# === Test: clear_used on clean fixture = 0 ===
flag="$(subset_stratify::clear_used "$CLEAN")"
assert "clear_used on clean = 0" "[ \"$flag\" = '0' ]"

# === Test: clear_used on /clear fixture = 1 ===
flag="$(subset_stratify::clear_used "$CLEAR_FIX")"
assert "clear_used on /clear fixture = 1" "[ \"$flag\" = '1' ]"

# === Test: missing transcript → rc=1 ===
set +e
subset_stratify::clear_used /nonexistent/path.jsonl >/dev/null 2>&1
rc=$?
set -e
assert "clear_used missing transcript → rc=1" "[ \"$rc\" = '1' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
