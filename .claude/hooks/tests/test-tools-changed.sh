#!/bin/bash
# Tests for E8-T7: tools_changed event in context-checkpoint.sh.
# Verifies hash-on-first-PreToolUse, idempotency via session flag,
# cross-session comparison, mismatch event, state file mode, regression
# of existing 28% gate, hash canonicalisation, absent/wrong-type tools,
# and BATON_EVENT_LOG_DISABLE kill-switch.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

mkstate() {
  local d; d=$(mktemp -d)
  echo "$d"
}

# Common runner matching test-hook-writers.sh style.
run_cc() {
  local stdin_json="$1" state_dir="$2" extra_exports="${3:-}"
  local log="$state_dir/hook-events.jsonl"
  local rc_file="$state_dir/rc"
  (
    export XDG_STATE_HOME="$state_dir/state"
    export BATON_EVENT_LOG="$log"
    # E23 off-by-default: open the collection gate so emitted events are written.
    export BATON_COLLECT=1
    export BATON_DIR="$state_dir/.baton"
    export BATON_PROGRESS_DIR="$state_dir/.baton/progress"
    export BATON_ARCHIVE_DIR="$state_dir/archive"
    export CLAUDE_PROJECT_DIR="$state_dir"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    [ -n "$extra_exports" ] && eval "$extra_exports"
    mkdir -p "$state_dir/.baton/progress" \
             "$state_dir/.baton/workstreams" \
             "$state_dir/.baton/terminals" \
             "$state_dir/state/baton"
    printf '%s' "$stdin_json" | "$HOOKS_DIR/context-checkpoint.sh" \
      >"$state_dir/stdout" 2>"$state_dir/stderr"
    echo "$?" > "$rc_file"
  )
  cat "$rc_file"
}

# Build a PreToolUse payload with tool_input.tools
mk_payload() {
  local sid="$1" cwd="$2" tools_json="${3:-null}"
  if [ "$tools_json" = "null" ]; then
    jq -cn --arg s "$sid" --arg c "$cwd" \
      '{session_id:$s, cwd:$c, tool_name:"Bash"}'
  else
    jq -cn --arg s "$sid" --arg c "$cwd" --argjson tools "$tools_json" \
      '{session_id:$s, cwd:$c, tool_name:"Bash", tool_input:{tools:$tools}}'
  fi
}

TOOLS_A='[{"name":"Bash","description":"run bash"},{"name":"Edit","description":"edit files"}]'
TOOLS_B='[{"name":"Bash","description":"run bash"},{"name":"Read","description":"read files"}]'

# Count matching lines in a log file safely (grep -c exits 1 on 0 matches)
count_events() {
  local pattern="$1" file="$2"
  grep -c "$pattern" "$file" 2>/dev/null || true
}

# ── Test 1: first invocation writes hash file; no tools_changed event ─────────
echo "## tools_changed event"
test_first_invocation_writes_state() {
  local d; d=$(mkstate)
  local sid="tc-first-$$"
  local state_file="$d/state/baton/tools-hash-state.json"

  local stdin; stdin=$(mk_payload "$sid" "$d" "$TOOLS_A")
  run_cc "$stdin" "$d" >/dev/null

  assert "T1: state file exists after first invocation" "[ -f '$state_file' ]"
  local hash; hash=$(jq -r '.last_tools_sha256' "$state_file" 2>/dev/null)
  assert "T1: state file has non-empty hash" "[ -n '$hash' ] && [ '$hash' != 'null' ]"
  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T1: no tools_changed on first invocation (no prior)" "[ '$ev_count' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_first_invocation_writes_state

# ── Test 2: same session, second invocation, same tools → no event (idempotent)
test_same_session_idempotent() {
  local d; d=$(mkstate)
  local sid="tc-idem-$$"
  local state_file="$d/state/baton/tools-hash-state.json"

  local stdin; stdin=$(mk_payload "$sid" "$d" "$TOOLS_A")
  # First call sets flag + writes state
  run_cc "$stdin" "$d" >/dev/null
  # Remove flag to simulate second call in same session (flag already set in /tmp)
  # Actually flag IS set; second call must skip the block
  run_cc "$stdin" "$d" >/dev/null

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T2: no tools_changed on same-session second call" "[ '$ev_count' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_same_session_idempotent

# ── Test 3: new session, same tools → no tools_changed (hashes match) ─────────
test_new_session_same_tools_no_event() {
  local d; d=$(mkstate)
  local sid1="tc-ns1-$$"
  local sid2="tc-ns2-$$"

  # Session 1: writes hash
  local stdin1; stdin1=$(mk_payload "$sid1" "$d" "$TOOLS_A")
  run_cc "$stdin1" "$d" >/dev/null

  # Session 2: same tools, different session_id (new flag file)
  local stdin2; stdin2=$(mk_payload "$sid2" "$d" "$TOOLS_A")
  run_cc "$stdin2" "$d" >/dev/null

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T3: no tools_changed when new session but same tools" "[ '$ev_count' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid1}" "/tmp/claude-tools-checked-${sid2}"
  rm -rf "$d"
}
test_new_session_same_tools_no_event

# ── Test 4: new session, different tools → tools_changed with required fields ──
test_new_session_different_tools_emits_event() {
  local d; d=$(mkstate)
  local sid1="tc-diff1-$$"
  local sid2="tc-diff2-$$"

  # Session 1: write hash for TOOLS_A
  local stdin1; stdin1=$(mk_payload "$sid1" "$d" "$TOOLS_A")
  run_cc "$stdin1" "$d" >/dev/null

  # Session 2: TOOLS_B → mismatch
  local stdin2; stdin2=$(mk_payload "$sid2" "$d" "$TOOLS_B")
  run_cc "$stdin2" "$d" >/dev/null

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T4: tools_changed emitted on mismatch" "[ '$ev_count' = '1' ]"

  local line; line=$(grep '"event":"tools_changed"' "$d/hook-events.jsonl" | head -n1)
  local ev; ev=$(printf '%s' "$line" | jq -r '.event')
  assert "T4: event name is tools_changed" "[ '$ev' = 'tools_changed' ]"

  # Spec T7 mandates the payload carry prior_hash + current_hash + session_id.
  # envelope does NOT redact these - assert their VALUES, not mere presence, so
  # a key-rename or value regression in the payload contract is caught.
  # (E8 RE-REVIEW-4: prior test only checked has("data"); a current_hash ->
  # cur_hash mutation in context-checkpoint.sh passed the whole suite.)
  local exp_prior exp_current
  exp_prior=$(printf '%s' "$TOOLS_A" | jq -cS '.' | sha256sum | awk '{print $1}')
  exp_current=$(printf '%s' "$TOOLS_B" | jq -cS '.' | sha256sum | awk '{print $1}')
  local got_prior got_current got_sid
  got_prior=$(printf '%s' "$line" | jq -r '.data.prior_hash')
  got_current=$(printf '%s' "$line" | jq -r '.data.current_hash')
  got_sid=$(printf '%s' "$line" | jq -r '.data.session_id')
  assert "T4: data.prior_hash = sha256(canonical TOOLS_A)" "[ '$got_prior' = '$exp_prior' ]"
  assert "T4: data.current_hash = sha256(canonical TOOLS_B)" "[ '$got_current' = '$exp_current' ]"
  assert "T4: data.session_id = session 2 id" "[ '$got_sid' = '$sid2' ]"
  assert "T4: prior_hash != current_hash" "[ '$got_prior' != '$got_current' ]"

  rm -f "/tmp/claude-tools-checked-${sid1}" "/tmp/claude-tools-checked-${sid2}"
  rm -rf "$d"
}
test_new_session_different_tools_emits_event

# ── Test 5: state file mode 0600 after write ───────────────────────────────────
test_state_file_mode() {
  local d; d=$(mkstate)
  local sid="tc-mode-$$"
  local state_file="$d/state/baton/tools-hash-state.json"

  local stdin; stdin=$(mk_payload "$sid" "$d" "$TOOLS_A")
  run_cc "$stdin" "$d" >/dev/null

  if [ -f "$state_file" ]; then
    local mode; mode=$(stat -c '%a' "$state_file")
    assert "T5: state file mode is 0600" "[ '$mode' = '600' ]"
  else
    assert "T5: state file mode is 0600" "false"
  fi

  rm -f "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_state_file_mode

# ── Test 6: 28% context-fill checkpoint logic still works (regression) ─────────
test_28pct_regression() {
  local d; d=$(mkstate)
  local sid="tc-reg-$$"
  echo "35" > "/tmp/claude-context-pct-${sid}"

  # No tool_input.tools - standard 28% path
  local stdin; stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  run_cc "$stdin" "$d" >/dev/null

  # Hook should have produced the checkpoint additionalContext output. Grep the
  # file directly - the additionalContext may contain shell metacharacters
  # (parens, quotes) that break eval-via-variable patterns.
  assert "T6: 28pct checkpoint additionalContext present" \
    "grep -q 'CHECKPOINT' '$d/stdout' 2>/dev/null"

  # PreToolUse envelope emitted
  local ev_count; ev_count=$(count_events '"event":"PreToolUse"' "$d/hook-events.jsonl")
  assert "T6: PreToolUse event still emitted" "[ '$ev_count' = '1' ]"

  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" \
        "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}" \
        "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_28pct_regression

# ── Test 7: hash is stable - different key order → same hash ─────────────────
test_hash_stability_key_order() {
  local d; d=$(mkstate)
  local sid_a="tc-hash-a-$$"
  local sid_b="tc-hash-b-$$"
  local state_dir="$d/state/baton"
  mkdir -p "$state_dir"

  # Two arrays with same tool objects but different internal key orders
  local tools_order1='[{"name":"Bash","description":"run bash"},{"name":"Edit","description":"edit files"}]'
  local tools_order2='[{"description":"run bash","name":"Bash"},{"description":"edit files","name":"Edit"}]'

  # Session A: tools_order1
  local stdin_a; stdin_a=$(mk_payload "$sid_a" "$d" "$tools_order1")
  run_cc "$stdin_a" "$d" >/dev/null
  local hash_a; hash_a=$(jq -r '.last_tools_sha256' "$state_dir/tools-hash-state.json" 2>/dev/null)

  rm -f "$state_dir/tools-hash-state.json" "/tmp/claude-tools-checked-${sid_a}"

  # Session B: tools_order2 (same content, different key order)
  local stdin_b; stdin_b=$(mk_payload "$sid_b" "$d" "$tools_order2")
  run_cc "$stdin_b" "$d" >/dev/null
  local hash_b; hash_b=$(jq -r '.last_tools_sha256' "$state_dir/tools-hash-state.json" 2>/dev/null)

  assert "T7: same tools different key order → same hash (jq -cS canonicalises)" \
    "[ '$hash_a' = '$hash_b' ] && [ -n '$hash_a' ]"

  rm -f "/tmp/claude-tools-checked-${sid_b}"
  rm -rf "$d"
}
test_hash_stability_key_order

# ── Test 8: tool_input.tools absent → no tools_changed, no error ──────────────
test_tools_absent_no_event() {
  local d; d=$(mkstate)
  local sid="tc-absent-$$"

  # Standard payload without tool_input.tools (PCT low → exits early, no event)
  local stdin; stdin=$(jq -cn --arg s "$sid" --arg c "$d" \
    '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  local rc; rc=$(run_cc "$stdin" "$d")

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T8: no tools_changed when tools absent" "[ '$ev_count' = '0' ]"
  assert "T8: hook exits 0 when tools absent" "[ '$rc' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_tools_absent_no_event

# ── Test 9: tool_input.tools is a string (not array) → exit silently ──────────
test_tools_string_not_array() {
  local d; d=$(mkstate)
  local sid="tc-str-$$"

  local stdin; stdin=$(jq -cn --arg s "$sid" --arg c "$d" \
    '{session_id:$s, cwd:$c, tool_name:"Bash", tool_input:{tools:"not-an-array"}}')
  local rc; rc=$(run_cc "$stdin" "$d")

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T9: no tools_changed when tools is a string" "[ '$ev_count' = '0' ]"
  assert "T9: hook exits 0 when tools is a string" "[ '$rc' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid}"
  rm -rf "$d"
}
test_tools_string_not_array

# ── Test 10: BATON_EVENT_LOG_DISABLE=1 → no tools_changed emitted ────────
test_killswitch_no_event() {
  local d; d=$(mkstate)
  local sid1="tc-ks1-$$"
  local sid2="tc-ks2-$$"

  # Session 1: write a hash without killswitch
  local stdin1; stdin1=$(mk_payload "$sid1" "$d" "$TOOLS_A")
  run_cc "$stdin1" "$d" >/dev/null

  # Session 2: different tools, killswitch active → envelope suppressed
  local stdin2; stdin2=$(mk_payload "$sid2" "$d" "$TOOLS_B")
  run_cc "$stdin2" "$d" "export BATON_EVENT_LOG_DISABLE=1" >/dev/null

  local ev_count; ev_count=$(count_events '"event":"tools_changed"' "$d/hook-events.jsonl")
  assert "T10: BATON_EVENT_LOG_DISABLE suppresses tools_changed" "[ '$ev_count' = '0' ]"

  rm -f "/tmp/claude-tools-checked-${sid1}" "/tmp/claude-tools-checked-${sid2}"
  rm -rf "$d"
}
test_killswitch_no_event

# ── Test 11: bash -n syntax check ────────────────────────────────────────────
test_syntax_check() {
  bash -n "$HOOKS_DIR/context-checkpoint.sh" 2>/tmp/tc-syntax-err-$$
  local rc=$?
  assert "T11: bash -n context-checkpoint.sh returns 0" "[ '$rc' = '0' ]"
  rm -f "/tmp/tc-syntax-err-$$"
}
test_syntax_check

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "================================"
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
