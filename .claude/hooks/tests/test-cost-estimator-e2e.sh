#!/bin/bash
# E2E integration test for E8 Cost Estimator (T9).
# Scenario: synthetic transcript → post-tool-batch.sh × 3 → cost_rollup events
# in hook-events.jsonl; turn 3 triggers cache_anomaly; tools/cost.sh USD total
# matches first-principles awk math; doctor surfaces WARNING + PRICING_VERIFIED_DATE.
set -u

export LC_ALL=C

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOK="$HOOKS_DIR/post-tool-batch.sh"
COST_SH="$REPO_DIR/tools/cost.sh"
DOCTOR_SH="$REPO_DIR/tools/doctor.sh"
COST_MODELS_LIB="$REPO_DIR/lib/cost-models.sh"

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

# Source PRICE table for first-principles math (no hardcoded totals).
# shellcheck disable=SC1090
source "$COST_MODELS_LIB"

# ---------------------------------------------------------------------------
# Turn definitions (round numbers from spec)
# ---------------------------------------------------------------------------
# Each turn: cache_read  cache_creation  input_tokens  output_tokens
# Turn 1: cache_read=0,  cache_creation=5000,  input=500, output=1500
# Turn 2: cache_read=5000, cache_creation=5000, input=500, output=1500
# Turn 3: cache_read=10000, cache_creation=15000, input=500, output=1500
#
# Anomaly logic: prior after turn 2 = 5000; turn 3 current = 15000; ratio=3.0 ≥ 2 → fires
#
# cost.sh parses each assistant message in the transcript and sums across all turns.
# cache_creation_input_tokens maps to cache_write_5m (via fallback in cost.sh).
#
# Total token sums across 3 turns:
#   TOT_CR  = 0 + 5000 + 10000  = 15000
#   TOT_CW5 = 5000 + 5000 + 15000 = 25000  (cache_creation → cache_write_5m)
#   TOT_CW1 = 0
#   TOT_FI  = 500 + 500 + 500 = 1500
#   TOT_OUT = 1500 + 1500 + 1500 = 4500
MODEL="claude-opus-4-7"

# Derive expected TOTAL from PRICE table (first-principles, no magic numbers).
P_CR=$(cost_models::price "$MODEL" cache_read)
P_CW5=$(cost_models::price "$MODEL" cache_write_5m)
P_CW1=$(cost_models::price "$MODEL" cache_write_1h)
P_FI=$(cost_models::price "$MODEL" base_in)
P_OUT=$(cost_models::price "$MODEL" base_out)

EXP_TOTAL=$(awk \
  -v p_cr="$P_CR" -v p_cw5="$P_CW5" -v p_cw1="$P_CW1" \
  -v p_fi="$P_FI" -v p_out="$P_OUT" \
  'BEGIN {
    tot_cr=15000; tot_cw5=25000; tot_cw1=0; tot_fi=1500; tot_out=4500
    cost = (tot_cr*p_cr + tot_cw5*p_cw5 + tot_cw1*p_cw1 + tot_fi*p_fi + tot_out*p_out) / 1000000
    printf "%.6f\n", cost
  }')

echo "## E8 Cost Estimator - End-to-End Integration Test"
echo "   Model: $MODEL"
echo "   Expected TOTAL (first-principles): \$$EXP_TOTAL"
echo

# ---------------------------------------------------------------------------
# 1. Isolated tmpdir - XDG_STATE_HOME + log path
# ---------------------------------------------------------------------------
TMPDIR_E2E="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_E2E"' EXIT

export XDG_STATE_HOME="$TMPDIR_E2E/state"
STATE_DIR="$TMPDIR_E2E/state/baton"
mkdir -p "$STATE_DIR"

LOG="$TMPDIR_E2E/events.jsonl"
export BATON_EVENT_LOG="$LOG"
export BATON_COLLECT=1

SESSION_ID="e2e-test-session-001"

# ---------------------------------------------------------------------------
# 2. Build per-turn transcript files
#    Each file contains a user line + ONE assistant message for that turn.
#    post-tool-batch.sh uses `tail -n 50 | jq -s [...] | last` so
#    each file must contain only that turn's assistant message.
# ---------------------------------------------------------------------------
# Helper to make a single-turn transcript
make_turn_transcript() {
  local path="$1"
  local cache_read="$2"
  local cache_creation="$3"
  local input_tokens="$4"
  local output_tokens="$5"
  cat > "$path" <<EOF
{"type":"user","message":{"role":"user","content":"test"}}
{"type":"assistant","message":{"role":"assistant","model":"${MODEL}","content":"ok","usage":{"input_tokens":${input_tokens},"output_tokens":${output_tokens},"cache_read_input_tokens":${cache_read},"cache_creation_input_tokens":${cache_creation}}}}
EOF
}

T1="$TMPDIR_E2E/turn1.jsonl"
T2="$TMPDIR_E2E/turn2.jsonl"
T3="$TMPDIR_E2E/turn3.jsonl"

make_turn_transcript "$T1"  0      5000  500 1500
make_turn_transcript "$T2"  5000   5000  500 1500
make_turn_transcript "$T3"  10000  15000 500 1500

# Also build the full 3-turn transcript for cost.sh (all turns concatenated).
FULL_TRANSCRIPT="$TMPDIR_E2E/all-turns.jsonl"
cat "$T1" "$T2" "$T3" > "$FULL_TRANSCRIPT"

# Helper to run the hook for a given turn
run_hook() {
  local session_id="$1" transcript="$2"
  local payload
  payload=$(printf '{"hook_event_name":"PostToolBatch","session_id":"%s","transcript_path":"%s","tool_calls":[]}' \
    "$session_id" "$transcript")
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$LOG" \
    XDG_STATE_HOME="$TMPDIR_E2E/state" \
    bash "$HOOK" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 3. Invoke hook 3 times
# ---------------------------------------------------------------------------
echo "--- Invoking post-tool-batch.sh (turn 1) ---"
run_hook "$SESSION_ID" "$T1"

echo "--- Invoking post-tool-batch.sh (turn 2) ---"
run_hook "$SESSION_ID" "$T2"

echo "--- Invoking post-tool-batch.sh (turn 3) ---"
run_hook "$SESSION_ID" "$T3"
echo

# ---------------------------------------------------------------------------
# 4. Assert event log contents
# ---------------------------------------------------------------------------
echo "## Assertions - event log"

# Count events
ROLLUP_COUNT=0
ANOMALY_COUNT=0
TOTAL_COUNT=0

if [ -f "$LOG" ]; then
  ROLLUP_COUNT=$(grep -c '"event":"cost_rollup"' "$LOG" 2>/dev/null || echo 0)
  ANOMALY_COUNT=$(grep -c '"event":"cache_anomaly"' "$LOG" 2>/dev/null || echo 0)
  TOTAL_COUNT=$(grep -c '"schema_version"' "$LOG" 2>/dev/null || echo 0)
fi

assert "EVENT-LOG: 3 cost_rollup events emitted" "[ '$ROLLUP_COUNT' -eq 3 ]"
assert "EVENT-LOG: 1 cache_anomaly event emitted (turn 3)" "[ '$ANOMALY_COUNT' -eq 1 ]"
assert "EVENT-LOG: 4 total events" "[ '$TOTAL_COUNT' -eq 4 ]"

# All events have schema_version=1
ALL_SV1=true
while IFS= read -r line; do
  sv=$(printf '%s' "$line" | jq -r '.schema_version // "none"' 2>/dev/null)
  [ "$sv" = "1" ] || ALL_SV1=false
done < <(grep '"schema_version"' "$LOG" 2>/dev/null || true)
assert "EVENT-LOG: all 4 events have schema_version=1" "[ '$ALL_SV1' = 'true' ]"

# cache_anomaly fields: prior_creation=5000, current_creation=15000, ratio≈3.0
ANOMALY_LINE=$(grep '"event":"cache_anomaly"' "$LOG" 2>/dev/null | tail -n1)
assert "ANOMALY: prior_creation=5000" \
  "printf '%s' \"\$ANOMALY_LINE\" | jq -e '.data.prior_creation==5000' >/dev/null 2>&1"
assert "ANOMALY: current_creation=15000" \
  "printf '%s' \"\$ANOMALY_LINE\" | jq -e '.data.current_creation==15000' >/dev/null 2>&1"
assert "ANOMALY: ratio≥3.0" \
  "printf '%s' \"\$ANOMALY_LINE\" | jq -e '.data.ratio >= 3.0' >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# 5. cost.sh total matches first-principles math
# ---------------------------------------------------------------------------
echo
echo "## Assertions - tools/cost.sh"

COST_OUT=$(BATON_TRANSCRIPT_PATH="$FULL_TRANSCRIPT" \
  bash "$COST_SH" --model "$MODEL" 2>/dev/null)

ACTUAL_TOTAL=$(printf '%s' "$COST_OUT" | grep '^TOTAL' | grep -oE '[0-9]+\.[0-9]+' | head -1)

assert "COST-SH: TOTAL output is non-empty" "[ -n '$ACTUAL_TOTAL' ]"
assert "COST-SH: TOTAL matches first-principles awk value" \
  "[ '$ACTUAL_TOTAL' = '$EXP_TOTAL' ]"
assert "COST-SH: disclaimer present (CC6)" \
  "printf '%s' \"\$COST_OUT\" | grep -qi 'token counts are an estimate'"

# ---------------------------------------------------------------------------
# 6. cost.sh --self-check exits 0
# ---------------------------------------------------------------------------
echo
echo "## Assertions - tools/cost.sh --self-check"

SELF_CHECK_RC=0
bash "$COST_SH" --self-check >/dev/null 2>&1 || SELF_CHECK_RC=$?
assert "COST-SH: --self-check exits 0" "[ '$SELF_CHECK_RC' -eq 0 ]"

# ---------------------------------------------------------------------------
# 7. doctor.sh surfaces WARNING (from cache_anomaly) + PRICING_VERIFIED_DATE
# ---------------------------------------------------------------------------
echo
echo "## Assertions - tools/doctor.sh"

# We need a stat shim so doctor reports tmpfs (not NFS warning - that would
# obscure the anomaly WARNING we're actually testing for).
SHIM_DIR="$TMPDIR_E2E/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/stat" <<'SH'
#!/bin/bash
if [ "$1" = "-f" ] && [ "$2" = "-c" ] && [ "$3" = "%T" ]; then
  echo "tmpfs"; exit 0
fi
exec /usr/bin/stat "$@"
SH
chmod +x "$SHIM_DIR/stat"

DOCTOR_OUT=$(BATON_EVENT_LOG="$LOG" PATH="$SHIM_DIR:$PATH" bash "$DOCTOR_SH" 2>&1 || true)

assert "DOCTOR: contains WARNING: (from cache_anomaly)" \
  "printf '%s' \"\$DOCTOR_OUT\" | grep -q 'WARNING:'"
assert "DOCTOR: contains PRICING_VERIFIED_DATE" \
  "printf '%s' \"\$DOCTOR_OUT\" | grep -q 'PRICING_VERIFIED_DATE'"

# ---------------------------------------------------------------------------
# 8. No-network grep - must produce 0 matches across 6 E8-touched files
# ---------------------------------------------------------------------------
echo
echo "## Assertions - no network calls in E8 files"

NO_NETWORK_RC=0
grep -rE "curl|wget|\bnc\b|/dev/tcp" \
  "$REPO_DIR/lib/cost-models.sh" \
  "$REPO_DIR/lib/tokens.sh" \
  "$REPO_DIR/tools/cost.sh" \
  "$REPO_DIR/tools/doctor.sh" \
  "$HOOKS_DIR/post-tool-batch.sh" \
  "$HOOKS_DIR/context-checkpoint.sh" \
  2>/dev/null && NO_NETWORK_RC=$? || NO_NETWORK_RC=$?
# grep exits 1 when no match found - that's the PASS case
assert "NO-NETWORK: grep finds 0 network calls in E8 files (exit 1 = no match)" \
  "[ '$NO_NETWORK_RC' -eq 1 ]"

# ---------------------------------------------------------------------------
# 9. Re-run all E8 test files (regression sweep)
# ---------------------------------------------------------------------------
echo
echo "## Regression sweep - all 8 other E8 test files"

E8_OTHERS=(
  test-cost-models.sh
  test-tokens.sh
  test-calibrate.sh
  test-cost.sh
  test-post-tool-batch.sh
  test-anomaly-detector.sh
  test-tools-changed.sh
  test-pre-warm.sh
)

for tf in "${E8_OTHERS[@]}"; do
  tfp="$HOOKS_DIR/tests/$tf"
  if [ ! -f "$tfp" ]; then
    echo "  SKIP  $tf (not found)"
    continue
  fi
  if bash "$tfp" >/dev/null 2>&1; then
    echo "  PASS  (regression) $tf"
    PASSED=$((PASSED+1))
  else
    echo "  FAIL  (regression) $tf"
    FAILED=$((FAILED+1))
    FAILED_CASES+=("regression:$tf")
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
