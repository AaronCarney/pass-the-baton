#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-code-execution.sh"
TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so emit-and-assert paths collect.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0

assert() {
  local label="$1"; shift
  local ok=0
  if [ "$#" -eq 1 ]; then
    eval "$1" >/dev/null 2>&1 && ok=1
  else
    "$@" >/dev/null 2>&1 && ok=1
  fi
  if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi
}

assert_jq() {
  local label="$1" expr="$2" json="$3"
  if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $label" >&2
  fi
}

assert 'hook file exists' test -x "$HOOK"

# Step 6: success-case (pytest exit=0)
rm -f "$BATON_EVENT_LOG"
export BATON_OUTCOME_PROXIES=1
bash "$HOOK" < "$REPO_ROOT/.claude/hooks/tests/fixtures/outcome-proxies/code-execution-input.json"
rc=$?
assert 'rc=0 on valid input' test "$rc" -eq 0
assert '1 event emitted' test "$(wc -l < "$BATON_EVENT_LOG")" -eq 1
evt=$(tail -1 "$BATON_EVENT_LOG")
assert_jq 'subkind=code_execution' '.data.subkind == "code_execution"' "$evt"
assert_jq 'success=true' '.data.success == true' "$evt"
assert_jq 'runner=pytest' '.data.runner == "pytest"' "$evt"
assert_jq 'exit_code=0' '.data.exit_code == 0' "$evt"
assert_jq 'no stdout field' '.data | has("stdout") | not' "$evt"
assert_jq 'no stderr field' '.data | has("stderr") | not' "$evt"
assert_jq 'no command field' '.data | has("command") | not' "$evt"
unset BATON_OUTCOME_PROXIES

# Step 7a: cargo test exit=1 → success=false
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
echo '{"tool_name":"Bash","tool_input":{"command":"cargo test --release"},"tool_response":{"exit_code":1}}' | bash "$HOOK"
evt=$(tail -1 "$BATON_EVENT_LOG")
assert_jq 'cargo failure → success=false' '.data.success == false' "$evt"
assert_jq 'cargo failure → runner=cargo-test' '.data.runner == "cargo-test"' "$evt"
assert_jq 'cargo failure → exit_code=1' '.data.exit_code == 1' "$evt"

# Step 7b: non-runner command → 0 events
rm -f "$BATON_EVENT_LOG"
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"exit_code":0}}' | bash "$HOOK"
assert 'non-runner command → 0 events' test ! -s "$BATON_EVENT_LOG"

# Step 7c: non-Bash tool → 0 events
rm -f "$BATON_EVENT_LOG"
echo '{"tool_name":"Read","tool_input":{"file_path":"/foo"},"tool_response":{}}' | bash "$HOOK"
assert 'non-Bash tool → 0 events' test ! -s "$BATON_EVENT_LOG"
unset BATON_OUTCOME_PROXIES

# Step 7d: consent off → 0 events even with valid runner
rm -f "$BATON_EVENT_LOG"
echo '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}}' | bash "$HOOK"
assert 'consent off → 0 events even with valid runner' test ! -s "$BATON_EVENT_LOG"

# === session_id propagation ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
echo '{"session_id":"sess-abc-789","tool_name":"Bash","tool_input":{"command":"pytest tests/"},"tool_response":{"exit_code":0}}' | bash "$HOOK"
evt=$(tail -1 "$BATON_EVENT_LOG")
assert_jq 'session_id from stdin lands in event payload' '.data.session_id == "sess-abc-789"' "$evt"

# session_id absent when stdin omits it (still emits the event)
rm -f "$BATON_EVENT_LOG"
echo '{"tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}}' | bash "$HOOK"
evt=$(tail -1 "$BATON_EVENT_LOG")
assert 'event still emitted when session_id absent from stdin' test -n "$evt"
assert_jq 'session_id key absent (NOT empty string) when stdin omits it' '.data | has("session_id") | not' "$evt"

# Assertion 5 (closeout iter-2): consent-off + session_id-in-stdin → ZERO outcome_proxy events.
# Locks L1 §E16 line 221: 'consent gate (BATON_OUTCOME_PROXIES=1) gates ALL emission, regardless of payload'.
# Defends against future refactors that re-order session_id extraction above the consent check.
unset BATON_OUTCOME_PROXIES
rm -f "$BATON_EVENT_LOG"
echo '{"session_id":"sess-locked-001","tool_name":"Bash","tool_input":{"command":"pytest"},"tool_response":{"exit_code":0}}' | bash "$HOOK"
locked_n=$(grep -c '"event":"outcome_proxy"' "$BATON_EVENT_LOG" 2>/dev/null || echo 0)
assert 'consent-off + session_id-in-stdin → zero outcome_proxy events (L1 line 221)' test "$locked_n" = "0"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
