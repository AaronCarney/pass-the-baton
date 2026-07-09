#!/bin/bash
# Tests for .claude/hooks/post-tool-batch.sh (E8-T6).
# Covers: cost_rollup emit, missing transcript, kill switch, log mode, syntax.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOK="$HOOKS_DIR/post-tool-batch.sh"

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

# Build a synthetic transcript JSONL fixture with one assistant message.
make_transcript() {
  local path="$1"
  cat > "$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":"hi","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200,"cache_creation_input_tokens":300}}}
EOF
}

# Build the PostToolBatch-style JSON payload.
make_payload() {
  local session_id="$1" transcript_path="$2"
  printf '{"hook_event_name":"PostToolBatch","session_id":"%s","transcript_path":"%s","tool_calls":[]}' \
    "$session_id" "$transcript_path"
}

echo "## .claude/hooks/post-tool-batch.sh"

# --- syntax check -------------------------------------------------------------
assert "SYNTAX: bash -n passes" "bash -n '$HOOK' 2>/dev/null"

# --- cost_rollup emitted for valid transcript ---------------------------------
run_cost_rollup_emit() {
  local d; d=$(mktemp -d)
  local transcript="$d/transcript.jsonl"
  local log="$d/events.jsonl"
  local state_dir="$d/state/baton"
  mkdir -p "$state_dir"
  make_transcript "$transcript"
  mkdir -p "$d/config/baton"; echo '{"threshold_pct":37}' > "$d/config/baton/config.json"
  local payload; payload=$(make_payload "sess-001" "$transcript")
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    XDG_CONFIG_HOME="$d/config" \
    BATON_COLLECT=1 \
    bash "$HOOK"
  assert "EMIT: log file exists after emit" "[ -f '$log' ]"
  local line; line=$(grep '"event"' "$log" | grep 'cost_rollup' | tail -n 1)
  assert "EMIT: event=cost_rollup" "echo '$line' | jq -e '.event==\"cost_rollup\"' >/dev/null 2>&1"
  assert "EMIT: schema_version=1" "echo '$line' | jq -e '.schema_version==1' >/dev/null 2>&1"
  assert "EMIT: data.cache_read extracted" "echo '$line' | jq -e '.data.cache_read==200' >/dev/null 2>&1"
  assert "EMIT: data.cache_write_5m extracted" "echo '$line' | jq -e '.data.cache_write_5m==300' >/dev/null 2>&1"
  assert "EMIT: data.cache_write_1h extracted" "echo '$line' | jq -e '.data.cache_write_1h==0' >/dev/null 2>&1"
  assert "EMIT: data.fresh_input extracted" "echo '$line' | jq -e '.data.fresh_input==100' >/dev/null 2>&1"
  assert "EMIT: data.output extracted" "echo '$line' | jq -e '.data.output==50' >/dev/null 2>&1"
  assert "EMIT: data.session_id from payload" "echo '$line' | jq -e '.data.session_id==\"sess-001\"' >/dev/null 2>&1"
  assert "EMIT: data.transcript_basename from path" "echo '$line' | jq -e '.data.transcript_basename==\"transcript.jsonl\"' >/dev/null 2>&1"
  assert "EMIT: data.turn_index = assistant-message count (1)" "echo '$line' | jq -e '.data.turn_index==1' >/dev/null 2>&1"
  assert "EMIT: data.model from transcript" "echo '$line' | jq -e '.data.model==\"claude-sonnet-4-6\"' >/dev/null 2>&1"
  assert "EMIT: data.threshold = active checkpoint threshold (37)" "echo '$line' | jq -e '.data.threshold==37' >/dev/null 2>&1"
  assert "EMIT: log file mode 0600" "[ \"\$(stat -c %a '$log')\" = '600' ]"
  rm -rf "$d"
}
run_cost_rollup_emit

# Spec line 367 / Brief 4 §10: 1h-TTL split is ephemeral_5m_input_tokens +
# ephemeral_1h_input_tokens. post-tool-batch must read the SAME field shape
# as tools/cost.sh. Regression (E8 RE-REVIEW-5): the hook read non-spec
# cache_creation_input_tokens_5min/_1hr, so a spec-conformant transcript
# made the two cost readers disagree (cost.sh: 8000 tok; rollup: 0). Every
# prior fixture wrote the non-spec keys, masking it.
run_cost_rollup_ephemeral_spec_shape() {
  local d; d=$(mktemp -d)
  local transcript="$d/transcript.jsonl"
  local log="$d/events.jsonl"
  cat > "$transcript" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":"hi","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"ephemeral_5m_input_tokens":8000,"ephemeral_1h_input_tokens":1000}}}
EOF
  local payload; payload=$(make_payload "sess-eph" "$transcript")
  printf '%s' "$payload" | BATON_EVENT_LOG="$log" XDG_STATE_HOME="$d/state" BATON_COLLECT=1 bash "$HOOK"
  local line; line=$(grep '"event"' "$log" | grep 'cost_rollup' | tail -n 1)
  assert "EPH-SPEC: cache_write_5m reads ephemeral_5m (=8000)" \
    "echo '$line' | jq -e '.data.cache_write_5m==8000' >/dev/null 2>&1"
  assert "EPH-SPEC: cache_write_1h reads ephemeral_1h (=1000)" \
    "echo '$line' | jq -e '.data.cache_write_1h==1000' >/dev/null 2>&1"
  # Cross-reader consistency: tools/cost.sh extracts the same split.
  local cost_out; cost_out=$(BATON_TRANSCRIPT_PATH="$transcript" \
    bash "$REPO_DIR/tools/cost.sh" --model claude-sonnet-4-6 2>/dev/null)
  assert "EPH-SPEC: cost.sh agrees - cache_write_5m line shows 8000 tok" \
    "echo '$cost_out' | grep -i 'cache_write_5m' | grep -q '8000'"
  rm -rf "$d"
}
run_cost_rollup_ephemeral_spec_shape

# FIX-7c: model must come from the transcript, never from env override.
run_cost_rollup_model_source() {
  local d; d=$(mktemp -d)
  local transcript="$d/transcript.jsonl"
  local log="$d/events.jsonl"
  mkdir -p "$d/state/baton"
  make_transcript "$transcript"
  local payload; payload=$(make_payload "sess-002" "$transcript")
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    BATON_COST_MODEL="claude-haiku-4-5" \
    BATON_COLLECT=1 \
    bash "$HOOK"
  local line; line=$(grep '"event"' "$log" | grep 'cost_rollup' | tail -n 1)
  assert "MODEL-SRC: data.model ignores BATON_COST_MODEL env" \
    "echo '$line' | jq -e '.data.model==\"claude-sonnet-4-6\"' >/dev/null 2>&1"
  rm -rf "$d"
}
run_cost_rollup_model_source

# --- missing transcript → exit 0, no emit ------------------------------------
run_missing_transcript() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local payload
  payload=$(make_payload "sess-002" "/nonexistent/path/transcript.jsonl")
  local rc=0
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    BATON_COLLECT=1 \
    bash "$HOOK" || rc=$?
  assert "MISSING-TRANSCRIPT: exit 0" "[ $rc -eq 0 ]"
  assert "MISSING-TRANSCRIPT: no event emitted" "[ ! -f '$log' ] || ! grep -q 'cost_rollup' '$log' 2>/dev/null"
  rm -rf "$d"
}
run_missing_transcript

# --- kill switch honoured -----------------------------------------------------
run_kill_switch() {
  local d; d=$(mktemp -d)
  local transcript="$d/transcript.jsonl"
  local log="$d/events.jsonl"
  make_transcript "$transcript"
  local payload; payload=$(make_payload "sess-003" "$transcript")
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    BATON_EVENT_LOG_DISABLE=1 \
    bash "$HOOK"
  assert "KILL-SWITCH: no event emitted when DISABLE=1" \
    "[ ! -f '$log' ] || ! grep -q 'cost_rollup' '$log' 2>/dev/null"
  rm -rf "$d"
}
run_kill_switch

# --- no network calls in hook source -----------------------------------------
assert "NO-NETWORK: no curl/wget/nc/dev-tcp in hook" \
  "! grep -qE 'curl|wget|\bnc\b|/dev/tcp' '$HOOK'"

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
