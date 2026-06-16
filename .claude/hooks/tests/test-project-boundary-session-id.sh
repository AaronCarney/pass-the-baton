#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0
assert() { local label="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi; }
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/projects.sh"

# Assertion 1: 7th positional arg lands in payload.
rm -f "$BATON_EVENT_LOG"
projects::emit_event start slug-a main-ws term-x '' 'description' 'sess-explicit-001'
evt=$(tail -1 "$BATON_EVENT_LOG")
assert 'session_id from 7th arg lands in payload' \
  "jq -e '.data.session_id == \"sess-explicit-001\"' <<<'$evt' >/dev/null"

# Assertion 2: env var fallback when no 7th arg.
rm -f "$BATON_EVENT_LOG"
BATON_SESSION_ID=sess-env-002 projects::emit_event start slug-b main-ws term-y '' 'desc'
evt=$(tail -1 "$BATON_EVENT_LOG")
assert 'session_id from env fallback lands in payload' \
  "jq -e '.data.session_id == \"sess-env-002\"' <<<'$evt' >/dev/null"

# Assertion 3: absent when neither provided (NOT empty string).
rm -f "$BATON_EVENT_LOG"
unset BATON_SESSION_ID
projects::emit_event start slug-c main-ws term-z '' 'desc'
evt=$(tail -1 "$BATON_EVENT_LOG")
assert 'session_id key absent when not provided' \
  "jq -e '.data | has(\"session_id\") | not' <<<'$evt' >/dev/null"

# Assertion 4: end-kind event also carries session_id.
rm -f "$BATON_EVENT_LOG"
projects::emit_event end slug-d main-ws term-q success 'note' 'sess-end-004'
evt=$(tail -1 "$BATON_EVENT_LOG")
assert 'end-kind: session_id present' \
  "jq -e '.data.session_id == \"sess-end-004\"' <<<'$evt' >/dev/null"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
