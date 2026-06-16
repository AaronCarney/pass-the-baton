#!/bin/bash
# Tests for E7-T3: hooks emit via envelope::emit.
# Verifies each of the 4 hooks: fires once, correct event name, required data keys
# present, forbidden keys absent (CC8), exits 0 on envelope failure, honors
# BATON_EVENT_LOG_DISABLE, stamps schema_version.

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
  local d
  d=$(mktemp -d)
  echo "$d"
}

# Common runner: invoke a hook with given stdin, in an isolated state dir.
# Env exports done in subshell - caller passes extra exports as $4.
# Args: hook_basename, stdin_json, state_dir, extra_exports
run_hook() {
  local hook="$1" stdin_json="$2" state_dir="$3" extra_exports="${4:-}"
  local log="$state_dir/hook-events.jsonl"
  local rc_file="$state_dir/rc"
  (
    export XDG_STATE_HOME="$state_dir/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$state_dir/.baton"
    export BATON_PROGRESS_DIR="$state_dir/.baton/progress"
    export BATON_ARCHIVE_DIR="$state_dir/archive"
    export CLAUDE_PROJECT_DIR="$state_dir"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    [ -n "$extra_exports" ] && eval "$extra_exports"
    mkdir -p "$state_dir/.baton/progress" "$state_dir/.baton/workstreams" "$state_dir/.baton/terminals"
    # Stub template so the write-trigger's V1 lint compares empty-vs-empty.
    # Tests here exercise envelope emission, not template enforcement.
    mkdir -p "$state_dir/share/templates" && : > "$state_dir/share/templates/free.md"
    printf '%s' "$stdin_json" | "$HOOKS_DIR/$hook" >"$state_dir/stdout" 2>"$state_dir/stderr"
    echo "$?" > "$rc_file"
  )
  cat "$rc_file"
}

# ---------- context-checkpoint.sh ----------
echo "## context-checkpoint.sh"

test_cc_fires_once() {
  local d; d=$(mkstate)
  local sid="sid-cc-$$"
  # Pre-stage pct file so the hook actually traverses past the "missing pct" exit
  echo "30" > "/tmp/claude-context-pct-${sid}"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  local rc; rc=$(run_hook "context-checkpoint.sh" "$stdin" "$d")
  local log="$d/hook-events.jsonl"
  local count; count=$(grep -c '"event":"PreToolUse"' "$log" 2>/dev/null || echo 0)
  assert "cc: fires exactly once" "[ '$count' = '1' ]"
  assert "cc: hook exit 0" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_cc_fires_once

test_cc_event_and_data() {
  local d; d=$(mkstate)
  local sid="sid-cc2-$$"
  echo "35" > "/tmp/claude-context-pct-${sid}"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Edit"}')
  run_hook "context-checkpoint.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"PreToolUse"' "$d/hook-events.jsonl" | head -n1)
  local ev; ev=$(printf '%s' "$line" | jq -r '.event')
  assert "cc: event=PreToolUse" "[ '$ev' = 'PreToolUse' ]"
  local sv; sv=$(printf '%s' "$line" | jq -r '.schema_version')
  assert "cc: schema_version=1" "[ '$sv' = '1' ]"
  local tn; tn=$(printf '%s' "$line" | jq -r '.data.tool_name')
  assert "cc: data.tool_name=Edit" "[ '$tn' = 'Edit' ]"
  local pct; pct=$(printf '%s' "$line" | jq -r '.data.context_pct')
  assert "cc: data.context_pct=35" "[ '$pct' = '35' ]"
  local thr; thr=$(printf '%s' "$line" | jq -r '.data.threshold')
  assert "cc: data.threshold present" "[ -n '$thr' ] && [ '$thr' != 'null' ]"
  local ps; ps=$(printf '%s' "$line" | jq -r '.data.pending_set')
  assert "cc: data.pending_set is boolean true" "[ '$ps' = 'true' ]"
  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_cc_event_and_data

test_cc_forbidden_keys() {
  local d; d=$(mkstate)
  local sid="sid-cc3-$$"
  echo "30" > "/tmp/claude-context-pct-${sid}"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash", prompt:"secret-prompt"}')
  run_hook "context-checkpoint.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"PreToolUse"' "$d/hook-events.jsonl" | head -n1)
  local has_prompt; has_prompt=$(printf '%s' "$line" | jq -r '.data | has("prompt")')
  assert "cc: no data.prompt" "[ '$has_prompt' = 'false' ]"
  local has_content; has_content=$(printf '%s' "$line" | jq -r '.data | has("content")')
  assert "cc: no data.content" "[ '$has_content' = 'false' ]"
  # No absolute paths in data values
  local has_abs; has_abs=$(printf '%s' "$line" | jq -r '[.data | .. | strings | select(startswith("/"))] | length')
  assert "cc: no absolute-path strings in data" "[ '$has_abs' = '0' ]"
  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_cc_forbidden_keys

test_cc_envelope_failure_safe() {
  local d; d=$(mkstate)
  local sid="sid-cc4-$$"
  echo "30" > "/tmp/claude-context-pct-${sid}"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  # Hide jq from PATH inside the subshell - envelope::emit needs jq, hook still must exit 0
  local rc
  rc=$(
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$d/hook-events.jsonl"
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    unset AGENT_SESSION_ID
    mkdir -p "$d/.baton/progress" "$d/.baton/workstreams" "$d/.baton/terminals"
    # Wrap the hook so it still receives jq input parsing (hook's own jq calls
    # need jq), but envelope::emit's jq fails. We simulate envelope-jq failure
    # by exporting a sabotage flag the hook's envelope path will read.
    export BATON_EVENT_LOG_FORCE_JQ_FAIL=1
    # Easier: just disable emission entirely with the documented kill-switch.
    # But the requirement is "envelope failure → hook still 0", not "disabled".
    # Simulate failure by setting log path to an unwritable dir.
    export BATON_EVENT_LOG="/proc/1/this-cannot-be-created/hook.jsonl"
    export BATON_COLLECT=1
    printf '%s' "$stdin" | "$HOOKS_DIR/context-checkpoint.sh" >/dev/null 2>"$d/stderr"
    echo "$?"
  )
  assert "cc: exits 0 when envelope cannot write" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_cc_envelope_failure_safe

test_cc_disable_killswitch() {
  local d; d=$(mkstate)
  local sid="sid-cc5-$$"
  echo "30" > "/tmp/claude-context-pct-${sid}"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  local rc; rc=$(run_hook "context-checkpoint.sh" "$stdin" "$d" "export BATON_EVENT_LOG_DISABLE=1")
  assert "cc: exits 0 with disable flag" "[ '$rc' = '0' ]"
  assert "cc: no log file when disabled" "[ ! -e '$d/hook-events.jsonl' ]"
  rm -f "/tmp/claude-context-pct-${sid}" "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_cc_disable_killswitch

# ---------- checkpoint-write-trigger.sh ----------
echo
echo "## checkpoint-write-trigger.sh"

# Helper: stage a pending checkpoint + workstream so the trigger fires
stage_pending() {
  local d="$1" sid="$2" ws_name="$3"
  local tracking="$d/.baton"
  local th; th=$(printf '%s:%s' "${USER:-x}" "test-term-$$" | md5sum | cut -d' ' -f1)
  mkdir -p "$tracking/workstreams" "$tracking/terminals" "$tracking/progress"
  jq -n --arg tid "test-term-$$" --arg ws "$ws_name" --arg ts "2026-01-01T00:00:00Z" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/${th}.json"
  jq -n --arg ws "$ws_name" --arg dn "$ws_name" --arg ts "2026-01-01T00:00:00Z" --arg p "" --arg pd "$d" \
    '{workstream:$ws, display_name:$dn, progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:$pd}' \
    > "$tracking/workstreams/${ws_name}.json"
  touch "/tmp/baton-pending-${sid}"
  echo "/tmp/dummy-pointer-${sid}" > "/tmp/claude-session-tracking-${sid}"
}

test_wt_fires_once() {
  local d; d=$(mkstate)
  local sid="sid-wt-$$"
  local ws="testws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  mkdir -p "$(dirname "$progress")"
  stage_pending "$d" "$sid" "$ws"
  echo "stub" > "$progress"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  local rc; rc=$(run_hook "checkpoint-write-trigger.sh" "$stdin" "$d")
  local count; count=$(grep -c '"event":"PostToolUse"' "$d/hook-events.jsonl" 2>/dev/null || echo 0)
  assert "wt: fires exactly once" "[ '$count' = '1' ]"
  assert "wt: hook exit 0" "[ '$rc' = '0' ]"
  rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}" "/tmp/claude-session-tracking-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_wt_fires_once

test_wt_event_and_data() {
  local d; d=$(mkstate)
  local sid="sid-wt2-$$"
  local ws="testws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  mkdir -p "$(dirname "$progress")"
  stage_pending "$d" "$sid" "$ws"
  echo "stub" > "$progress"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  run_hook "checkpoint-write-trigger.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"PostToolUse"' "$d/hook-events.jsonl" | head -n1)
  local ev; ev=$(printf '%s' "$line" | jq -r '.event')
  assert "wt: event=PostToolUse" "[ '$ev' = 'PostToolUse' ]"
  local sv; sv=$(printf '%s' "$line" | jq -r '.schema_version')
  assert "wt: schema_version=1" "[ '$sv' = '1' ]"
  local tn; tn=$(printf '%s' "$line" | jq -r '.data.tool_name')
  assert "wt: data.tool_name=Write" "[ '$tn' = 'Write' ]"
  local wsv; wsv=$(printf '%s' "$line" | jq -r '.data.workstream')
  assert "wt: data.workstream=testws" "[ '$wsv' = 'testws' ]"
  local thv; thv=$(printf '%s' "$line" | jq -r '.data.terminal_hash')
  assert "wt: data.terminal_hash non-empty" "[ -n '$thv' ] && [ '$thv' != 'null' ]"
  local bn; bn=$(printf '%s' "$line" | jq -r '.data.progress_file_basename')
  assert "wt: data.progress_file_basename is basename only" "[ '$bn' = 'progress-${ws}-abc.md' ]"
  rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}" "/tmp/claude-session-tracking-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_wt_event_and_data

test_wt_forbidden_keys() {
  local d; d=$(mkstate)
  local sid="sid-wt3-$$"
  local ws="testws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  mkdir -p "$(dirname "$progress")"
  stage_pending "$d" "$sid" "$ws"
  echo "stub" > "$progress"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f, content:"secret"}}')
  run_hook "checkpoint-write-trigger.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"PostToolUse"' "$d/hook-events.jsonl" | head -n1)
  local has_content; has_content=$(printf '%s' "$line" | jq -r '.data | has("content")')
  assert "wt: no data.content" "[ '$has_content' = 'false' ]"
  local has_prompt; has_prompt=$(printf '%s' "$line" | jq -r '.data | has("prompt")')
  assert "wt: no data.prompt" "[ '$has_prompt' = 'false' ]"
  # progress_file_basename must not be an absolute path
  local bn; bn=$(printf '%s' "$line" | jq -r '.data.progress_file_basename')
  case "$bn" in
    /*) BN_OK=false ;;
    *)  BN_OK=true ;;
  esac
  assert "wt: progress_file_basename is not absolute" "[ '$BN_OK' = 'true' ]"
  rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}" "/tmp/claude-session-tracking-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_wt_forbidden_keys

test_wt_envelope_failure_safe() {
  local d; d=$(mkstate)
  local sid="sid-wt4-$$"
  local ws="testws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  mkdir -p "$(dirname "$progress")"
  stage_pending "$d" "$sid" "$ws"
  echo "stub" > "$progress"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  local rc
  rc=$(
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="/proc/1/cannot/write.jsonl"
    export BATON_COLLECT=1
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    unset AGENT_SESSION_ID
    printf '%s' "$stdin" | "$HOOKS_DIR/checkpoint-write-trigger.sh" >/dev/null 2>"$d/stderr"
    echo "$?"
  )
  assert "wt: exits 0 when envelope cannot write" "[ '$rc' = '0' ]"
  rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}" "/tmp/claude-session-tracking-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_wt_envelope_failure_safe

test_wt_disable_killswitch() {
  local d; d=$(mkstate)
  local sid="sid-wt5-$$"
  local ws="testws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  mkdir -p "$(dirname "$progress")"
  stage_pending "$d" "$sid" "$ws"
  echo "stub" > "$progress"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  local rc; rc=$(run_hook "checkpoint-write-trigger.sh" "$stdin" "$d" "export BATON_EVENT_LOG_DISABLE=1")
  assert "wt: exits 0 with disable flag" "[ '$rc' = '0' ]"
  assert "wt: no log file when disabled" "[ ! -e '$d/hook-events.jsonl' ]"
  rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}" "/tmp/claude-session-tracking-${sid}" "/tmp/baton-archive-${sid}"
  rm -rf "$d"
}
test_wt_disable_killswitch

# ---------- session-start.sh ----------
echo
echo "## session-start.sh"

test_ss_fires_once() {
  local d; d=$(mkstate)
  local sid="sid-ss-$$"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, source:"startup"}')
  local rc; rc=$(run_hook "session-start.sh" "$stdin" "$d")
  local count; count=$(grep -c '"event":"SessionStart"' "$d/hook-events.jsonl" 2>/dev/null || echo 0)
  assert "ss: fires exactly once" "[ '$count' = '1' ]"
  assert "ss: hook exit 0" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_ss_fires_once

test_ss_event_and_data() {
  local d; d=$(mkstate)
  local sid="sid-ss2-$$"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, source:"resume"}')
  run_hook "session-start.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"SessionStart"' "$d/hook-events.jsonl" | head -n1)
  local ev; ev=$(printf '%s' "$line" | jq -r '.event')
  assert "ss: event=SessionStart" "[ '$ev' = 'SessionStart' ]"
  local sv; sv=$(printf '%s' "$line" | jq -r '.schema_version')
  assert "ss: schema_version=1" "[ '$sv' = '1' ]"
  local mt; mt=$(printf '%s' "$line" | jq -r '.data.matcher')
  assert "ss: data.matcher present" "[ -n '$mt' ] && [ '$mt' != 'null' ]"
  local wsv; wsv=$(printf '%s' "$line" | jq -r '.data.workstream')
  assert "ss: data.workstream present" "[ -n '$wsv' ] && [ '$wsv' != 'null' ]"
  local thv; thv=$(printf '%s' "$line" | jq -r '.data.terminal_hash')
  assert "ss: data.terminal_hash non-empty" "[ -n '$thv' ] && [ '$thv' != 'null' ]"
  local bf; bf=$(printf '%s' "$line" | jq -r '.data.binding_found')
  assert "ss: data.binding_found is boolean" "[ '$bf' = 'true' ] || [ '$bf' = 'false' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_ss_event_and_data

test_ss_forbidden_keys() {
  local d; d=$(mkstate)
  local sid="sid-ss3-$$"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, source:"startup", prompt:"x"}')
  run_hook "session-start.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"SessionStart"' "$d/hook-events.jsonl" | head -n1)
  local has_prompt; has_prompt=$(printf '%s' "$line" | jq -r '.data | has("prompt")')
  assert "ss: no data.prompt" "[ '$has_prompt' = 'false' ]"
  local has_content; has_content=$(printf '%s' "$line" | jq -r '.data | has("content")')
  assert "ss: no data.content" "[ '$has_content' = 'false' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_ss_forbidden_keys

test_ss_envelope_failure_safe() {
  local d; d=$(mkstate)
  local sid="sid-ss4-$$"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, source:"startup"}')
  local rc
  rc=$(
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="/proc/1/cannot/write.jsonl"
    export BATON_COLLECT=1
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    unset AGENT_SESSION_ID
    mkdir -p "$d/.baton/progress" "$d/.baton/workstreams" "$d/.baton/terminals"
    printf '%s' "$stdin" | "$HOOKS_DIR/session-start.sh" >/dev/null 2>"$d/stderr"
    echo "$?"
  )
  assert "ss: exits 0 when envelope cannot write" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_ss_envelope_failure_safe

test_ss_disable_killswitch() {
  local d; d=$(mkstate)
  local sid="sid-ss5-$$"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, source:"startup"}')
  local rc; rc=$(run_hook "session-start.sh" "$stdin" "$d" "export BATON_EVENT_LOG_DISABLE=1")
  assert "ss: exits 0 with disable flag" "[ '$rc' = '0' ]"
  assert "ss: no log file when disabled" "[ ! -e '$d/hook-events.jsonl' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_ss_disable_killswitch

# ---------- project-detect.sh ----------
echo
echo "## project-detect.sh"

# project-detect needs a per-session tracking pointer + workstream record
stage_pd_state() {
  local d="$1" sid="$2"
  local tracking="$d/.baton"
  mkdir -p "$tracking/workstreams"
  jq -n --arg ws "wsX" --arg dn "wsX" --arg ts "2026-01-01T00:00:00Z" --arg pd "$d" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:$ts, project_dir:$pd}' \
    > "$tracking/workstreams/wsX.json"
  local ptr="/tmp/claude-session-tracking-${sid}"
  local tfile="$d/track-${sid}.json"
  jq -n --arg ws "wsX" '{workstream:$ws}' > "$tfile"
  echo "$tfile" > "$ptr"
}

test_pd_fires_once() {
  local d; d=$(mkstate)
  local sid="sid-pd-$$"
  stage_pd_state "$d" "$sid"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, prompt:"hello world from user"}')
  local rc; rc=$(run_hook "project-detect.sh" "$stdin" "$d")
  local count; count=$(grep -c '"event":"UserPromptSubmit"' "$d/hook-events.jsonl" 2>/dev/null || echo 0)
  assert "pd: fires exactly once" "[ '$count' = '1' ]"
  assert "pd: hook exit 0" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_pd_fires_once

test_pd_event_and_data() {
  local d; d=$(mkstate)
  local sid="sid-pd2-$$"
  stage_pd_state "$d" "$sid"
  local prompt_text="hello world from user"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" --arg p "$prompt_text" '{session_id:$s, cwd:$c, prompt:$p}')
  run_hook "project-detect.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"UserPromptSubmit"' "$d/hook-events.jsonl" | head -n1)
  local ev; ev=$(printf '%s' "$line" | jq -r '.event')
  assert "pd: event=UserPromptSubmit" "[ '$ev' = 'UserPromptSubmit' ]"
  local sv; sv=$(printf '%s' "$line" | jq -r '.schema_version')
  assert "pd: schema_version=1" "[ '$sv' = '1' ]"
  local pb; pb=$(printf '%s' "$line" | jq -r '.data.prompt_bytes')
  local expected=${#prompt_text}
  assert "pd: data.prompt_bytes matches input length" "[ '$pb' = '$expected' ]"
  local hk; hk=$(printf '%s' "$line" | jq -r '.data | has("project_slug")')
  assert "pd: data.project_slug key present" "[ '$hk' = 'true' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_pd_event_and_data

test_pd_forbidden_keys() {
  local d; d=$(mkstate)
  local sid="sid-pd3-$$"
  stage_pd_state "$d" "$sid"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, prompt:"SUPER-SECRET-PROMPT-CONTENT"}')
  run_hook "project-detect.sh" "$stdin" "$d" >/dev/null
  local line; line=$(grep '"event":"UserPromptSubmit"' "$d/hook-events.jsonl" | head -n1)
  local has_prompt; has_prompt=$(printf '%s' "$line" | jq -r '.data | has("prompt")')
  assert "pd: no data.prompt (CC8)" "[ '$has_prompt' = 'false' ]"
  local has_content; has_content=$(printf '%s' "$line" | jq -r '.data | has("content")')
  assert "pd: no data.content" "[ '$has_content' = 'false' ]"
  # Prompt text must not appear anywhere in the envelope
  local has_secret
  if grep -q "SUPER-SECRET-PROMPT-CONTENT" "$d/hook-events.jsonl" 2>/dev/null; then
    has_secret=1
  else
    has_secret=0
  fi
  assert "pd: prompt text never appears in log" "[ '$has_secret' = '0' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_pd_forbidden_keys

test_pd_envelope_failure_safe() {
  local d; d=$(mkstate)
  local sid="sid-pd4-$$"
  stage_pd_state "$d" "$sid"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, prompt:"x"}')
  local rc
  rc=$(
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="/proc/1/cannot/write.jsonl"
    export BATON_COLLECT=1
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    unset AGENT_SESSION_ID
    printf '%s' "$stdin" | "$HOOKS_DIR/project-detect.sh" >/dev/null 2>"$d/stderr"
    echo "$?"
  )
  assert "pd: exits 0 when envelope cannot write" "[ '$rc' = '0' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_pd_envelope_failure_safe

test_pd_disable_killswitch() {
  local d; d=$(mkstate)
  local sid="sid-pd5-$$"
  stage_pd_state "$d" "$sid"
  local stdin
  stdin=$(jq -cn --arg s "$sid" --arg c "$d" '{session_id:$s, cwd:$c, prompt:"x"}')
  local rc; rc=$(run_hook "project-detect.sh" "$stdin" "$d" "export BATON_EVENT_LOG_DISABLE=1")
  assert "pd: exits 0 with disable flag" "[ '$rc' = '0' ]"
  assert "pd: no log file when disabled" "[ ! -e '$d/hook-events.jsonl' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"
  rm -rf "$d"
}
test_pd_disable_killswitch

# ---------- summary ----------
echo
echo "================================"
echo "PASS $PASS / FAIL $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
