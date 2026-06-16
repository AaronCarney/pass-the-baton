#!/bin/bash
# End-to-end integration test for E7 event-log pipeline.
# Proves: hook fires → envelope built → on-disk record → query reads it back.
# Usage: bash .claude/hooks/tests/test-event-log-e2e.sh
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
ENVELOPE="$HOOKS_DIR/lib/envelope.sh"
QUERY="$REPO_DIR/tools/query.sh"
DOCTOR="$REPO_DIR/tools/doctor.sh"

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

# Shared isolated state dir for the full E2E scenario.
E2E_DIR=$(mktemp -d)
E2E_LOG="$E2E_DIR/hook-events.jsonl"

# ── Shared helpers ────────────────────────────────────────────────────────────

# stage_pending mirrors test-hook-writers.sh: sets up the minimal tracking
# structure needed by checkpoint-write-trigger.sh.
stage_pending() {
  local d="$1" sid="$2" ws_name="$3"
  local tracking="$d/.baton"
  local th; th=$(printf '%s:%s' "${USER:-x}" "test-term-$$" | md5sum | cut -d' ' -f1)
  mkdir -p "$tracking/workstreams" "$tracking/terminals" "$tracking/progress"
  jq -n --arg tid "test-term-$$" --arg ws "$ws_name" --arg ts "2026-01-01T00:00:00Z" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/${th}.json"
  jq -n --arg ws "$ws_name" --arg dn "$ws_name" --arg ts "2026-01-01T00:00:00Z" --arg pd "$d" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:$ts, project_dir:$pd}' \
    > "$tracking/workstreams/${ws_name}.json"
  touch "/tmp/baton-pending-${sid}"
  echo "/tmp/dummy-pointer-${sid}" > "/tmp/claude-session-tracking-${sid}"
}

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

have_duckdb() { command -v duckdb >/dev/null 2>&1; }

# ── E2E scenario: fire all 4 hooks ───────────────────────────────────────────
echo "## E2E setup: fire 4 hooks into shared log"

run_four_hooks() {
  local d="$E2E_DIR"
  local log="$E2E_LOG"
  mkdir -p "$d/.baton/progress" "$d/.baton/workstreams" "$d/.baton/terminals"
  # Stub template so the write-trigger's V1 lint compares empty-vs-empty.
  # This scenario exercises envelope emission, not template enforcement.
  mkdir -p "$d/share/templates" && : > "$d/share/templates/free.md"

  # --- 1. context-checkpoint.sh (PreToolUse) ---
  local sid_cc="sid-e2e-cc-$$"
  echo "30" > "/tmp/claude-context-pct-${sid_cc}"
  local stdin_cc
  stdin_cc=$(jq -cn --arg s "$sid_cc" --arg c "$d" '{session_id:$s, cwd:$c, tool_name:"Bash"}')
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    printf '%s' "$stdin_cc" | "$HOOKS_DIR/context-checkpoint.sh" >/dev/null 2>/dev/null
  )
  rm -f "/tmp/claude-context-pct-${sid_cc}" "/tmp/claude-context-triggered-${sid_cc}" \
    "/tmp/baton-pending-${sid_cc}" "/tmp/baton-archive-${sid_cc}"

  # --- 2. checkpoint-write-trigger.sh (PostToolUse) ---
  local sid_wt="sid-e2e-wt-$$"
  local ws="e2e-ws"
  local progress="$d/.baton/progress/progress-${ws}-abc.md"
  echo "stub" > "$progress"
  stage_pending "$d" "$sid_wt" "$ws"
  local stdin_wt
  stdin_wt=$(jq -cn --arg s "$sid_wt" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    printf '%s' "$stdin_wt" | "$HOOKS_DIR/checkpoint-write-trigger.sh" >/dev/null 2>/dev/null
  )
  rm -f "/tmp/baton-pending-${sid_wt}" "/tmp/baton-done-${sid_wt}" \
    "/tmp/claude-session-tracking-${sid_wt}" "/tmp/baton-archive-${sid_wt}"

  # --- 3. session-start.sh (SessionStart) ---
  local sid_ss="sid-e2e-ss-$$"
  local stdin_ss
  stdin_ss=$(jq -cn --arg s "$sid_ss" --arg c "$d" '{session_id:$s, cwd:$c, source:"startup"}')
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    printf '%s' "$stdin_ss" | "$HOOKS_DIR/session-start.sh" >/dev/null 2>/dev/null
  )
  rm -f "/tmp/claude-session-tracking-${sid_ss}"

  # --- 4. project-detect.sh (UserPromptSubmit) ---
  local sid_pd="sid-e2e-pd-$$"
  stage_pd_state "$d" "$sid_pd"
  local stdin_pd
  stdin_pd=$(jq -cn --arg s "$sid_pd" --arg c "$d" '{session_id:$s, cwd:$c, prompt:"hello e2e world"}')
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="test-term-$$"
    export BATON_COLLECT=1
    unset AGENT_SESSION_ID
    unset BATON_EVENT_LOG_DISABLE
    printf '%s' "$stdin_pd" | "$HOOKS_DIR/project-detect.sh" >/dev/null 2>/dev/null
  )
  rm -f "/tmp/claude-session-tracking-${sid_pd}"
}

run_four_hooks

# ── Group A: On-disk record assertions ───────────────────────────────────────
echo
echo "## A: on-disk record assertions"

# A1. Log file exists after 4 hook invocations.
assert "A1: hook-events.jsonl exists" "[ -e '$E2E_LOG' ]"

# A2. File mode is 0600.
MODE=$(stat -c '%a' "$E2E_LOG" 2>/dev/null || echo '?')
assert "A2: log mode is 0600" "[ '$MODE' = '600' ]"

# A3. File contains exactly 4 lines (one per hook).
LINE_COUNT=$(wc -l < "$E2E_LOG")
assert "A3: log contains 4 lines" "[ '$LINE_COUNT' = '4' ]"

# A4. Every line parses as JSON with schema_version=1.
BAD_SCHEMA=$(while IFS= read -r line; do
  sv=$(printf '%s' "$line" | jq -r '.schema_version' 2>/dev/null)
  [ "$sv" != "1" ] && echo "bad"
done < "$E2E_LOG" | wc -l)
assert "A4: every record has schema_version=1" "[ '$BAD_SCHEMA' = '0' ]"

# A5. 4 distinct event values: PreToolUse, PostToolUse, SessionStart, UserPromptSubmit.
EVENTS=$(jq -r '.event' < "$E2E_LOG" | sort | tr '\n' ',')
assert "A5: PreToolUse present" "echo '$EVENTS' | grep -q 'PreToolUse'"
assert "A5: PostToolUse present" "echo '$EVENTS' | grep -q 'PostToolUse'"
assert "A5: SessionStart present" "echo '$EVENTS' | grep -q 'SessionStart'"
assert "A5: UserPromptSubmit present" "echo '$EVENTS' | grep -q 'UserPromptSubmit'"

# ── Group B: DuckDB query assertions ─────────────────────────────────────────
echo
echo "## B: DuckDB query assertions"

if ! have_duckdb; then
  echo "  SKIP  B1-B4: duckdb not on PATH (graceful degradation)"
  PASS=$((PASS+0))  # SKIPs don't count toward FAIL
else
  # B1. Query exits 0.
  QUERY_OUT=$(BATON_EVENT_LOG="$E2E_LOG" bash "$QUERY" \
    "SELECT event, COUNT(*)::BIGINT AS cnt FROM events GROUP BY event" 2>/dev/null)
  QUERY_RC=$?
  assert "B1: query exits 0" "[ '$QUERY_RC' = '0' ]"

  # B2. Output contains all 4 event names.
  assert "B2: query output has PreToolUse" "echo '$QUERY_OUT' | grep -q 'PreToolUse'"
  assert "B2: query output has PostToolUse" "echo '$QUERY_OUT' | grep -q 'PostToolUse'"
  assert "B2: query output has SessionStart" "echo '$QUERY_OUT' | grep -q 'SessionStart'"
  assert "B2: query output has UserPromptSubmit" "echo '$QUERY_OUT' | grep -q 'UserPromptSubmit'"

  # B3. Each event appears with count 1.
  # DuckDB prints aligned columns; '1' must appear somewhere in each row.
  assert "B3: each event count is 1" \
    "echo '$QUERY_OUT' | grep -E 'PreToolUse|PostToolUse|SessionStart|UserPromptSubmit' | \
     awk '{found=0; for(i=1;i<=NF;i++){if(\$i==\"1\")found=1} if(!found){print \"BAD\"; exit 1}}'"
fi

# ── Group C: Doctor assertions ────────────────────────────────────────────────
echo
echo "## C: doctor assertions"

# C1. doctor.sh exits 0 with the e2e log in place (mode 0600, local tmpfs).
# E19 T8 fallout: stub doctor's new crontab + statusline backstop checks so a
# host missing those wirings can't drive WARNED=1 → exit 1 here.
C_BIN=$(mktemp -d)
cat > "$C_BIN/crontab" <<'SH'
#!/bin/bash
[ "$1" = "-l" ] && { echo '*/30 * * * * cleanup-cron-wrapper'; exit 0; }
exit 0
SH
chmod +x "$C_BIN/crontab"
C_SETTINGS="$C_BIN/settings.json"
cat > "$C_SETTINGS" <<'SH'
{"statusLine":{"command":"bash $HOME/.claude/assets/baton-pct.sh $SESSION_ID"}}
SH
DOCTOR_OUT=$(BATON_EVENT_LOG="$E2E_LOG" \
  BATON_DOCTOR_SETTINGS="$C_SETTINGS" \
  PATH="$C_BIN:$PATH" bash "$DOCTOR" 2>&1)
DOCTOR_RC=$?
rm -rf "$C_BIN"
assert "C1: doctor exits 0 (clean state)" "[ '$DOCTOR_RC' = '0' ]"
assert "C2: doctor prints summary: ok" "echo '$DOCTOR_OUT' | grep -q 'summary: ok'"

# ── Group D: Static-analysis assertions ───────────────────────────────────────
echo
echo "## D: static-analysis assertions"

# D1. No network primitives in lib/ or tools/, EXCEPT the one sanctioned
# count_tokens calibration seam (E8/CC8: opt-in, $ANTHROPIC_API_KEY-gated) and
# the T3 LLM classifier (retry-intent-classify.sh, $ANTHROPIC_API_KEY-gated).
# outcome-proxy-commit-survival.sh is excluded because it uses `$nc` as a jq
# variable name (n_commits abbreviation), not the netcat command.
# Use \bnc\b to avoid false positives on substrings like 'sync', 'function', etc.
assert "D1: no curl/wget/nc/dev/tcp in .claude/hooks/lib/ or tools/ (calibrate + retry-intent-classify + outcome-proxy-commit-survival seams excepted)" \
  "! grep -rqE --exclude=calibrate-bytes-per-token.sh --exclude=retry-intent-classify.sh --exclude=outcome-proxy-commit-survival.sh 'curl|wget|\bnc\b|/dev/tcp' '$HOOKS_DIR/lib/' '$REPO_DIR/tools/'"

# D2. Hook files do not directly append to hook-events.jsonl (must go via envelope).
assert "D2: hooks do not directly append to hook-events" \
  "! grep -rnqE '>> *[\x27\"]?[^\x27\"]*hook-events' \
    '$HOOKS_DIR/context-checkpoint.sh' \
    '$HOOKS_DIR/checkpoint-write-trigger.sh' \
    '$HOOKS_DIR/session-start.sh' \
    '$HOOKS_DIR/project-detect.sh'"

# ── Group E: CHANGELOG presence ───────────────────────────────────────────────
echo
echo "## E: CHANGELOG assertions"

CHANGELOG="$REPO_DIR/CHANGELOG.md"
assert "E1: CHANGELOG.md exists" "[ -f '$CHANGELOG' ]"
assert "E2: CHANGELOG mentions schema_version=1" "grep -q 'schema_version=1' '$CHANGELOG'"
assert "E3: CHANGELOG has E7 entry" "grep -q 'E7' '$CHANGELOG'"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$E2E_DIR"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
