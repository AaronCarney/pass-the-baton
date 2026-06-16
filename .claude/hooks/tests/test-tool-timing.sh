#!/bin/bash
# Tests for .claude/hooks/tool-timing.sh - optional per-tool latency hook.
# Covers: off-path (env unset / =0), on-path emit, duration extraction,
# malformed-input guard, workstream binding, hook_overhead_ms self-measurement,
# stdin-drain on off-path, kill-switch interaction with envelope.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/tool-timing.sh"

# E23 off-by-default: open the collection gate globally; the hook subshells
# inherit it. OFF/kill-switch paths return before emit, so this is orthogonal.
export BATON_COLLECT=1

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

make_payload() {
  # Mimic the SDK's PostToolUse stdin (per Claude Code hooks docs).
  local tool_name="${1:-Read}"
  local duration_ms="${2:-142}"
  local session_id="${3:-sess-001}"
  local tool_use_id="${4:-toolu_test01}"
  jq -cn \
    --arg tn "$tool_name" \
    --argjson d "$duration_ms" \
    --arg sid "$session_id" \
    --arg tui "$tool_use_id" \
    '{hook_event_name:"PostToolUse",
      session_id:$sid,
      cwd:"/tmp",
      tool_name:$tn,
      tool_input:{},
      tool_response:{success:true},
      tool_use_id:$tui,
      duration_ms:$d}'
}

echo "## .claude/hooks/tool-timing.sh"

# --- syntax check -------------------------------------------------------------
assert "SYNTAX: bash -n passes" "bash -n '$HOOK' 2>/dev/null"

# --- OFF path: BATON_TIMING unset → no event emitted --------------------
run_off_path_unset() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  make_payload "Bash" 50 | \
    env -u BATON_TIMING \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  assert "OFF unset: log NOT created" "[ ! -f '$log' ]"
  rm -rf "$d"
}
run_off_path_unset

# --- OFF path: BATON_TIMING=0 → no event emitted ------------------------
run_off_path_zero() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  make_payload "Bash" 50 | \
    BATON_TIMING=0 \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  assert "OFF =0: log NOT created" "[ ! -f '$log' ]"
  rm -rf "$d"
}
run_off_path_zero

# --- OFF path: stdin drained (no SIGPIPE) ------------------------------------
run_off_path_drains_stdin() {
  local d; d=$(mktemp -d)
  # Pipe a large-ish payload and confirm hook returns 0 (didn't choke on stdin).
  local payload; payload=$(make_payload "Bash" 50)
  payload="$payload$(printf '%*s' 4096 '')"   # pad with whitespace
  local rc
  printf '%s' "$payload" | \
    BATON_TIMING=0 \
    BATON_EVENT_LOG="$d/events.jsonl" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  rc=$?
  assert "OFF: exit code 0 on large stdin" "[ '$rc' = '0' ]"
  rm -rf "$d"
}
run_off_path_drains_stdin

# --- ON path: tool_call event emitted with expected fields -------------------
run_on_path_emit() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  make_payload "Bash" 142 "sess-A" "toolu_aaa" | \
    BATON_TIMING=1 \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  assert "ON: log file created" "[ -f '$log' ]"
  local line; line=$(tail -n 1 "$log")
  assert "ON: event=tool_call" "echo '$line' | jq -e '.event==\"tool_call\"' >/dev/null 2>&1"
  assert "ON: schema_version=1" "echo '$line' | jq -e '.schema_version==1' >/dev/null 2>&1"
  assert "ON: data.tool_name extracted" "echo '$line' | jq -e '.data.tool_name==\"Bash\"' >/dev/null 2>&1"
  assert "ON: data.duration_ms extracted" "echo '$line' | jq -e '.data.duration_ms==142' >/dev/null 2>&1"
  assert "ON: data.tool_use_id extracted" "echo '$line' | jq -e '.data.tool_use_id==\"toolu_aaa\"' >/dev/null 2>&1"
  assert "ON: data.hook_overhead_ms is integer" "echo '$line' | jq -e '.data.hook_overhead_ms | type == \"number\"' >/dev/null 2>&1"
  assert "ON: data.hook_overhead_ms >= 0" "echo '$line' | jq -e '.data.hook_overhead_ms >= 0' >/dev/null 2>&1"
  assert "ON: log file mode 0600" "[ \"\$(stat -c %a '$log')\" = '600' ]"
  rm -rf "$d"
}
run_on_path_emit

# --- ON path: missing duration_ms → coerced to 0 -----------------------------
run_on_missing_duration() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  # Payload missing duration_ms.
  jq -cn '{hook_event_name:"PostToolUse",session_id:"s",cwd:"/tmp",
          tool_name:"Read",tool_input:{},tool_response:{}}' | \
    BATON_TIMING=1 \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  local line; line=$(tail -n 1 "$log")
  assert "ON: missing duration_ms → 0" "echo '$line' | jq -e '.data.duration_ms==0' >/dev/null 2>&1"
  rm -rf "$d"
}
run_on_missing_duration

# --- ON path: malformed duration_ms (string) → coerced to 0 ------------------
run_on_malformed_duration() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  jq -cn '{hook_event_name:"PostToolUse",session_id:"s",cwd:"/tmp",
          tool_name:"Read",tool_input:{},tool_response:{},
          duration_ms:"not-a-number"}' | \
    BATON_TIMING=1 \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  local line; line=$(tail -n 1 "$log")
  assert "ON: malformed duration_ms → 0" "echo '$line' | jq -e '.data.duration_ms==0' >/dev/null 2>&1"
  rm -rf "$d"
}
run_on_malformed_duration

# --- ON path: workstream binding resolved from terminal file -----------------
run_on_workstream_resolution() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local proj="$d/proj"
  mkdir -p "$proj/.baton/terminals"
  # Derive the same term_hash the hook will compute, then plant a binding.
  local th
  th=$(CLAUDE_PROJECT_DIR="$proj" bash -c '
    source "'"$HOOKS_DIR"'/lib/workstream-lib.sh"
    term_hash
  ')
  printf '{"workstream":"my-ws"}\n' > "$proj/.baton/terminals/${th}.json"
  make_payload "Read" 25 | \
    BATON_TIMING=1 \
    BATON_PROJECT_DIR="$proj" \
    CLAUDE_PROJECT_DIR="$proj" \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  local line; line=$(tail -n 1 "$log")
  assert "ON: workstream resolved" "echo '$line' | jq -e '.data.workstream==\"my-ws\"' >/dev/null 2>&1"
  assert "ON: terminal_hash present" "echo '$line' | jq -e '.data.terminal_hash != \"\"' >/dev/null 2>&1"
  rm -rf "$d"
}
run_on_workstream_resolution

# --- ON path: no terminal binding → workstream empty, hook still emits -------
run_on_no_binding() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local proj="$d/proj"
  mkdir -p "$proj"
  make_payload "Read" 10 | \
    BATON_TIMING=1 \
    CLAUDE_PROJECT_DIR="$proj" \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  local line; line=$(tail -n 1 "$log")
  assert "ON: no binding → workstream empty" "echo '$line' | jq -e '.data.workstream==\"\"' >/dev/null 2>&1"
  assert "ON: no binding → event still emitted" "echo '$line' | jq -e '.event==\"tool_call\"' >/dev/null 2>&1"
  rm -rf "$d"
}
run_on_no_binding

# --- ON path: BATON_EVENT_LOG_DISABLE=1 suppresses emit -----------------
run_envelope_kill_switch() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  make_payload "Bash" 50 | \
    BATON_TIMING=1 \
    BATON_EVENT_LOG_DISABLE=1 \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    bash "$HOOK"
  assert "ON + kill switch: log NOT created" "[ ! -f '$log' ]"
  rm -rf "$d"
}
run_envelope_kill_switch

# --- summary ------------------------------------------------------------------
echo ""
echo "$PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
