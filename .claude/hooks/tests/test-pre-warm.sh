#!/bin/bash
# Tests for E8-T8: session-start.sh pre-warm block.
# Verifies gate conditions, mock seam, event emission, and stderr output.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    printf "  PASS  %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    printf "  FAIL  %s\n" "$name"
  fi
}

mkstate() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.baton/workstreams" "$d/.baton/terminals" "$d/.baton/progress" \
           "$d/state"
  echo "$d"
}

# Create a system file of at least 4096 bytes
make_system_file() {
  local path="$1"
  python3 -c "print('A' * 4200)" > "$path"
}

# Run session-start.sh with a given matcher and extra env vars.
# Captures stdout, stderr, rc. Provides mock override for prewarm::_request.
# Args: state_dir, matcher, mock_response_code, mock_response_body, extra_exports
#
# Mock seam: when mock_rc is non-empty, a shim bash script is injected via
# PREWARM_REQUEST_CMD env var. The hook sources it instead of running real curl.
# PREWARM_MOCK_REQUEST_FILE env var is passed through so the mock can capture
# the request body that was piped to it.
run_session_start() {
  local state_dir="$1"
  local matcher="$2"
  local mock_rc="${3:-}"       # empty = no mock (real curl)
  local mock_body="${4:-}"
  local extra_exports="${5:-}"
  local log="$state_dir/hook-events.jsonl"
  local req_file="$state_dir/mock_request.json"
  local stderr_file="$state_dir/stderr.txt"
  local stdout_file="$state_dir/stdout.txt"
  local rc_file="$state_dir/rc.txt"

  # Write mock shim if requested
  local mock_shim=""
  if [ -n "$mock_rc" ]; then
    mock_shim="$state_dir/mock_prewarm_request.sh"
    cat > "$mock_shim" <<MOCKEOF
#!/bin/bash
# Mock shim for prewarm::_request.
# Output format: line 1 = HTTP status code, line 2 = JSON response body.
# If PREWARM_MOCK_REQUEST_FILE is set, write the received request body there.
body=\$(cat)
if [ -n "\${PREWARM_MOCK_REQUEST_FILE:-}" ]; then
  printf '%s' "\$body" > "\$PREWARM_MOCK_REQUEST_FILE"
fi
# Line 1: status; Line 2: body
printf '%s\n' '${mock_rc}'
printf '%s' '${mock_body}'
[ '${mock_rc}' = '200' ] && exit 0 || exit 1
MOCKEOF
    chmod +x "$mock_shim"
  fi

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
    export PREWARM_MOCK_REQUEST_FILE="$req_file"
    [ -n "$mock_shim" ] && export PREWARM_REQUEST_SHIM="$mock_shim"
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    unset WORKSTREAM
    [ -n "$extra_exports" ] && eval "$extra_exports"

    stdin_json=$(jq -cn --arg src "$matcher" --arg sid "test-session-$$" --arg cwd "$state_dir" \
      '{source:$src, session_id:$sid, cwd:$cwd}')
    printf '%s' "$stdin_json" | bash "$HOOKS_DIR/session-start.sh" \
      >"$stdout_file" 2>"$stderr_file"
    echo $? > "$rc_file"
  )

  echo "$state_dir"
}

event_count() {
  local log="$1" event="$2"
  [ -f "$log" ] || { echo 0; return; }
  # grep -c exits 1 when count is 0; capture output without the || fallback.
  local n; n=$(grep -c "\"event\":\"${event}\"" "$log" 2>/dev/null); echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# Test 1: Default env (BATON_PREWARM unset) - no event, no stderr, exit 0
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: default env - gate off ==="
D1=$(mkstate)
run_session_start "$D1" "clear" "" "" "" > /dev/null

assert "T1: exit 0" "[ \"\$(cat $D1/rc.txt)\" = '0' ]"
assert "T1: no prewarm_ok event" "[ \"\$(event_count $D1/hook-events.jsonl prewarm_ok)\" = '0' ]"
assert "T1: no prewarm_failed event" "[ \"\$(event_count $D1/hook-events.jsonl prewarm_failed)\" = '0' ]"
assert "T1: no pre-warm stderr" "! grep -q 'pre-warm' $D1/stderr.txt 2>/dev/null"

# ---------------------------------------------------------------------------
# Test 2: BATON_PREWARM=1 but matcher=startup - gate fail (wrong matcher)
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: BATON_PREWARM=1, matcher=startup - gate fail ==="
D2=$(mkstate)
make_system_file "$D2/system.txt"
run_session_start "$D2" "startup" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D2/system.txt" > /dev/null

assert "T2: exit 0" "[ \"\$(cat $D2/rc.txt)\" = '0' ]"
assert "T2: no prewarm_ok event" "[ \"\$(event_count $D2/hook-events.jsonl prewarm_ok)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 3: BATON_PREWARM=1, matcher=clear, ANTHROPIC_API_KEY empty - gate fail
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: BATON_PREWARM=1, clear, no API key - gate fail ==="
D3=$(mkstate)
make_system_file "$D3/system.txt"
run_session_start "$D3" "clear" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "export BATON_PREWARM=1; unset ANTHROPIC_API_KEY; export BATON_PREWARM_SYSTEM_FILE=$D3/system.txt" > /dev/null

assert "T3: no prewarm_ok event" "[ \"\$(event_count $D3/hook-events.jsonl prewarm_ok)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 4: BATON_PREWARM=1, matcher=resume, API key set, system file missing - gate fail
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: BATON_PREWARM=1, resume, system file missing - gate fail ==="
D4=$(mkstate)
run_session_start "$D4" "resume" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D4/nonexistent.txt" > /dev/null

assert "T4: no prewarm_ok event" "[ \"\$(event_count $D4/hook-events.jsonl prewarm_ok)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 5: BATON_PREWARM=1, matcher=resume, all gates pass, mock 200 - prewarm_ok emitted
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: all gates pass, mock 200 - prewarm_ok emitted ==="
D5=$(mkstate)
make_system_file "$D5/system.txt"
MOCK_RESPONSE='{"usage":{"cache_creation_input_tokens":18000}}'
run_session_start "$D5" "resume" "200" "$MOCK_RESPONSE" \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D5/system.txt" > /dev/null

assert "T5: prewarm_ok event emitted" "[ \"\$(event_count $D5/hook-events.jsonl prewarm_ok)\" = '1' ]"
assert "T5: stderr contains 'pre-warm (5m) requested'" "grep -q 'pre-warm (5m) requested' $D5/stderr.txt 2>/dev/null"
# FIX-6: prewarm_ok must emit the resolved pinned id, not the alias.
T5_MODEL=$(grep '"event":"prewarm_ok"' "$D5/hook-events.jsonl" | jq -r 'select(.event=="prewarm_ok") | .data.model' 2>/dev/null)
assert "T5: prewarm_ok .data.model is pinned id (ends -20260101)" "[[ \"$T5_MODEL\" == *-20260101 ]]"
assert "T5: prewarm_ok .data.model != bare alias" "[ \"$T5_MODEL\" != 'claude-opus-4-7' ]"
assert "T5: exit 0" "[ \"\$(cat $D5/rc.txt)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 5b (FIX-7e): system file present but < 4096 bytes - no event, exit 0
# ---------------------------------------------------------------------------
echo ""
echo "=== T5b: system file < 4096 bytes - no event ==="
D5B=$(mkstate)
python3 -c "print('A' * 100)" > "$D5B/system.txt"
run_session_start "$D5B" "resume" "200" '{"usage":{"cache_creation_input_tokens":18000}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D5B/system.txt" > /dev/null
assert "T5b: no prewarm_ok event (file too small)" "[ \"\$(event_count $D5B/hook-events.jsonl prewarm_ok)\" = '0' ]"
assert "T5b: no prewarm_failed event (gated before request)" "[ \"\$(event_count $D5B/hook-events.jsonl prewarm_failed)\" = '0' ]"
assert "T5b: exit 0" "[ \"\$(cat $D5B/rc.txt)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 6: Same setup but mock 400 - prewarm_failed emitted with status_code=400
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: mock 400 - prewarm_failed emitted ==="
D6=$(mkstate)
make_system_file "$D6/system.txt"
MOCK_400_RESPONSE='{"error":{"type":"invalid_request_error","message":"bad request"}}'
run_session_start "$D6" "resume" "400" "$MOCK_400_RESPONSE" \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D6/system.txt" > /dev/null

assert "T6: prewarm_failed event emitted" "[ \"\$(event_count $D6/hook-events.jsonl prewarm_failed)\" = '1' ]"
assert "T6: status_code=400 in event" "grep -q '\"status_code\":\"400\"' $D6/hook-events.jsonl 2>/dev/null"
assert "T6: exit 0 (non-blocking)" "[ \"\$(cat $D6/rc.txt)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 7: Request body sent to mock contains required fields
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: request body has max_tokens=0, cache_control ephemeral, system content ==="
D7=$(mkstate)
make_system_file "$D7/system.txt"
run_session_start "$D7" "clear" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D7/system.txt" > /dev/null

REQFILE="$D7/mock_request.json"
assert "T7: request file written" "[ -f '$REQFILE' ]"
assert "T7: max_tokens=0" "jq -e '.max_tokens == 0' '$REQFILE' >/dev/null 2>&1"
assert "T7: cache_control ephemeral" "jq -e '.system[0].cache_control.type == \"ephemeral\"' '$REQFILE' >/dev/null 2>&1"
assert "T7: system content matches file" "jq -r '.system[0].text' '$REQFILE' 2>/dev/null | diff - <(cat $D7/system.txt) >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# Test 8: Existing session-start behavior still works (regression - exits 0, emits SessionStart)
# ---------------------------------------------------------------------------
echo ""
echo "=== T8: regression - SessionStart event still emitted when PREWARM=1 ==="
D8=$(mkstate)
make_system_file "$D8/system.txt"
run_session_start "$D8" "clear" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D8/system.txt" > /dev/null

assert "T8: SessionStart event emitted" "[ \"\$(event_count $D8/hook-events.jsonl SessionStart)\" = '1' ]"
assert "T8: exit 0 with prewarm enabled" "[ \"\$(cat $D8/rc.txt)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 9: bash -n syntax check
# ---------------------------------------------------------------------------
echo ""
echo "=== T9: syntax check ==="
assert "T9: bash -n on session-start.sh" "bash -n '$HOOKS_DIR/session-start.sh' 2>/dev/null"

# ---------------------------------------------------------------------------
# Test 10: BATON_EVENT_LOG_DISABLE=1 suppresses prewarm_ok/prewarm_failed
# ---------------------------------------------------------------------------
echo ""
echo "=== T10: BATON_EVENT_LOG_DISABLE=1 suppresses emit ==="
D10=$(mkstate)
make_system_file "$D10/system.txt"
run_session_start "$D10" "resume" "200" '{"usage":{"cache_creation_input_tokens":1000}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D10/system.txt; export BATON_EVENT_LOG_DISABLE=1" > /dev/null

assert "T10: no prewarm_ok event when LOG_DISABLE=1" "[ \"\$(event_count $D10/hook-events.jsonl prewarm_ok)\" = '0' ]"

# ---------------------------------------------------------------------------
# Test 11: Stderr cost line format - for opus-4-7, 18000 tokens: 18000*6.25/1000000 = $0.1125
# ---------------------------------------------------------------------------
echo ""
echo "=== T11: stderr cost line has correct estimated cost ==="
D11=$(mkstate)
make_system_file "$D11/system.txt"
run_session_start "$D11" "clear" "200" '{"usage":{"cache_creation_input_tokens":18000}}' \
  "export BATON_PREWARM=1; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D11/system.txt; export BATON_COST_MODEL=claude-opus-4-7" > /dev/null

assert "T11: stderr contains 'estimated cost'" "grep -q 'estimated cost' $D11/stderr.txt 2>/dev/null"
# Pin the exact PRICE-derived amount: 18000 cache_creation × opus-4-7
# cache_write_5m ($6.25/MTok) / 1e6 = $0.1125. A wrong primitive (e.g.
# cache_read $0.50 → $0.0090) would still start with "$0." and slip past a
# loose prefix grep, so assert the precise value.
assert "T11: estimated cost is exactly \$0.1125 (18000×6.25/1e6)" \
  "grep 'estimated cost' $D11/stderr.txt 2>/dev/null | grep -qF '\$0.1125'"

# ---------------------------------------------------------------------------
# Test 12: BATON_PREWARM gate isolated - every OTHER gate passes
# (matcher=resume, API key set, system file >=4096, mock 200) but PREWARM
# unset → still NO billable call. Regression (E8 RE-REVIEW-3): removing the
# `BATON_PREWARM=1 || return 0` gate passed the whole suite because T1
# (the only PREWARM-unset case) also lacked an API key, so a downstream gate
# masked the missing opt-in - the cost-control toggle was unproven.
# ---------------------------------------------------------------------------
echo ""
echo "=== T12: PREWARM unset but all other gates pass - no billable call ==="
D12=$(mkstate)
make_system_file "$D12/system.txt"
run_session_start "$D12" "resume" "200" '{"usage":{"cache_creation_input_tokens":100}}' \
  "unset BATON_PREWARM; export ANTHROPIC_API_KEY=fake; export BATON_PREWARM_SYSTEM_FILE=$D12/system.txt" > /dev/null

assert "T12: exit 0" "[ \"\$(cat $D12/rc.txt)\" = '0' ]"
assert "T12: no prewarm_ok event (PREWARM gate held)" "[ \"\$(event_count $D12/hook-events.jsonl prewarm_ok)\" = '0' ]"
assert "T12: no prewarm_failed event" "[ \"\$(event_count $D12/hook-events.jsonl prewarm_failed)\" = '0' ]"
assert "T12: no pre-warm stderr" "! grep -q 'pre-warm' $D12/stderr.txt 2>/dev/null"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "${#FAILED_CASES[@]}" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
fi

[ "$FAIL" -eq 0 ]
