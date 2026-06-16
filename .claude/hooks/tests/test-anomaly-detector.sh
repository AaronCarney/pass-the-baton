#!/bin/bash
# Tests for anomaly detection in post-tool-batch.sh + doctor extensions (E8-T6).
# Covers: cache_anomaly emit, state isolation, doctor anomaly surface,
#         doctor pricing-freshness surface.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOK="$HOOKS_DIR/post-tool-batch.sh"
DOCTOR="$REPO_DIR/tools/doctor.sh"

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

# Build a synthetic transcript JSONL with a given cache_creation_input_tokens value.
make_transcript() {
  local path="$1" cache_creation="$2"
  cat > "$path" <<EOF
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":"ok","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":${cache_creation}}}}
EOF
}

# Run the hook with a given transcript and session_id.
run_hook() {
  local d="$1" session_id="$2" transcript="$3" log="$4"
  local payload
  payload=$(printf '{"hook_event_name":"PostToolBatch","session_id":"%s","transcript_path":"%s","tool_calls":[]}' \
    "$session_id" "$transcript")
  printf '%s' "$payload" | \
    BATON_EVENT_LOG="$log" \
    XDG_STATE_HOME="$d/state" \
    BATON_COLLECT=1 \
    bash "$HOOK" 2>/dev/null
}

echo "## Anomaly detection - cache_anomaly events"

# --- two turns: 5000 → 15000 (3× prior) → anomaly emitted -------------------
run_anomaly_3x() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl" t2="$d/t2.jsonl"
  make_transcript "$t1" 5000
  make_transcript "$t2" 15000

  run_hook "$d" "sess-anom-3x" "$t1" "$log"
  run_hook "$d" "sess-anom-3x" "$t2" "$log"

  assert "ANOMALY-3X: cache_anomaly event emitted" \
    "grep -q '\"cache_anomaly\"' '$log' 2>/dev/null"
  assert "ANOMALY-3X: ratio ≥ 3" \
    "grep '\"cache_anomaly\"' '$log' | tail -n1 | jq -e '.data.ratio >= 3' >/dev/null 2>&1"
  assert "ANOMALY-3X: prior_creation=5000" \
    "grep '\"cache_anomaly\"' '$log' | tail -n1 | jq -e '.data.prior_creation==5000' >/dev/null 2>&1"
  assert "ANOMALY-3X: current_creation=15000" \
    "grep '\"cache_anomaly\"' '$log' | tail -n1 | jq -e '.data.current_creation==15000' >/dev/null 2>&1"
  rm -rf "$d"
}
run_anomaly_3x

# --- two turns: ratio < 2 → no anomaly ---------------------------------------
run_no_anomaly_below_2x() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl" t2="$d/t2.jsonl"
  make_transcript "$t1" 5000
  make_transcript "$t2" 9000   # 1.8×, below threshold

  run_hook "$d" "sess-below2x" "$t1" "$log"
  run_hook "$d" "sess-below2x" "$t2" "$log"

  assert "NO-ANOMALY-BELOW2X: no cache_anomaly event" \
    "! grep -q '\"cache_anomaly\"' '$log' 2>/dev/null"
  rm -rf "$d"
}
run_no_anomaly_below_2x

# --- exactly 2× prior → anomaly fires (inclusive boundary) -------------------
# Spec line 450: current >= 2 × prior (inclusive). No prior fixture hit the
# exact 2× point, so an -ge -> -gt mutation in post-tool-batch.sh went
# uncaught. E8 RE-REVIEW-5 (low-sev weak-test hardening).
run_anomaly_exact_2x() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl" t2="$d/t2.jsonl"
  make_transcript "$t1" 5000
  make_transcript "$t2" 10000   # exactly 2× - boundary must trigger

  run_hook "$d" "sess-exact2x" "$t1" "$log"
  run_hook "$d" "sess-exact2x" "$t2" "$log"

  assert "ANOMALY-EXACT2X: cache_anomaly fires at exactly 2×" \
    "grep -q '\"cache_anomaly\"' '$log' 2>/dev/null"
  assert "ANOMALY-EXACT2X: ratio == 2" \
    "grep '\"cache_anomaly\"' '$log' | tail -n1 | jq -e '.data.ratio==2' >/dev/null 2>&1"
  rm -rf "$d"
}
run_anomaly_exact_2x

# --- first turn (no prior state) → no anomaly ---------------------------------
run_no_anomaly_first_turn() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl"
  make_transcript "$t1" 5000

  run_hook "$d" "sess-first" "$t1" "$log"

  assert "NO-ANOMALY-FIRST-TURN: no cache_anomaly on first turn" \
    "! grep -q '\"cache_anomaly\"' '$log' 2>/dev/null"
  rm -rf "$d"
}
run_no_anomaly_first_turn

# --- state file mode 0600 -----------------------------------------------------
run_state_file_mode() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl"
  make_transcript "$t1" 5000
  run_hook "$d" "sess-mode" "$t1" "$log"
  local state_file="$d/state/baton/cost-anomaly-state.json"
  assert "STATE-FILE-MODE: state file mode 0600" \
    "[ \"\$(stat -c %a '$state_file' 2>/dev/null)\" = '600' ]"
  rm -rf "$d"
}
run_state_file_mode

# --- anomaly state isolated per session_id ------------------------------------
run_session_isolation() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local t1="$d/t1.jsonl" t2="$d/t2.jsonl"
  make_transcript "$t1" 5000
  make_transcript "$t2" 15000

  # Session A: turn 1 (5000)
  run_hook "$d" "sess-iso-A" "$t1" "$log"
  # Session B: turn 1 (15000) - B has no prior state, should not anomaly even vs A's 5000
  run_hook "$d" "sess-iso-B" "$t2" "$log"

  assert "SESSION-ISOLATION: no cross-session anomaly" \
    "! grep -q '\"cache_anomaly\"' '$log' 2>/dev/null"
  rm -rf "$d"
}
run_session_isolation

echo ""
echo "## Doctor extension - cache anomaly surface"

# Build a stat shim for doctor (tmpfs, no NFS warning).
make_stat_shim() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/stat" <<'SH'
#!/bin/bash
if [ "$1" = "-f" ] && [ "$2" = "-c" ] && [ "$3" = "%T" ]; then
  echo "tmpfs"; exit 0
fi
exec /usr/bin/stat "$@"
SH
  chmod +x "$dir/stat"
}

# --- doctor with 1 cache_anomaly in last 24h → WARNING -----------------------
run_doctor_anomaly_warn() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  # Create a log file with a recent cache_anomaly event (mode 0600).
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"schema_version":1,"event":"cache_anomaly","ts":"%s","data":{"session_id":"x","prior_creation":5000,"current_creation":15000,"ratio":3.0}}\n' \
    "$ts" > "$log"
  chmod 0600 "$log"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "DOCTOR-ANOMALY-WARN: WARNING with count 1" \
    "echo '$out' | grep -qE 'WARNING:.*1 cache anomaly'"
  rm -rf "$d"
}
run_doctor_anomaly_warn

# --- doctor with 0 anomalies → OK --------------------------------------------
run_doctor_anomaly_ok() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  # Log with only a cost_rollup event.
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"schema_version":1,"event":"cost_rollup","ts":"%s","data":{}}\n' "$ts" > "$log"
  chmod 0600 "$log"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "DOCTOR-ANOMALY-OK: OK line for no anomalies" \
    "echo '$out' | grep -qE 'OK:.*no cache anomalies'"
  rm -rf "$d"
}
run_doctor_anomaly_ok

# --- doctor with a >24h-old cache_anomaly → OK (window filter) ---------------
# Regression: deleting/widening the [ entry_epoch -ge cutoff ] filter in
# doctor.sh made a stale anomaly falsely trigger a "last 24h" WARNING and
# went uncaught (every other anomaly fixture uses ts=now). See E8 RE-REVIEW-3.
run_doctor_anomaly_stale_window() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  local old_ts; old_ts=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v -3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  printf '{"schema_version":1,"event":"cache_anomaly","ts":"%s","data":{"session_id":"x","prior_creation":5000,"current_creation":15000,"ratio":3.0}}\n' \
    "$old_ts" > "$log"
  chmod 0600 "$log"
  local out
  out=$(BATON_EVENT_LOG="$log" PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "DOCTOR-ANOMALY-WINDOW: 3-day-old anomaly does NOT count (OK line)" \
    "echo '$out' | grep -qE 'OK:.*no cache anomalies'"
  assert "DOCTOR-ANOMALY-WINDOW: no spurious WARNING for stale anomaly" \
    "! echo '$out' | grep -qE 'WARNING:.*cache anomaly'"
  rm -rf "$d"
}
run_doctor_anomaly_stale_window

echo ""
echo "## Doctor extension - pricing freshness"

# --- PRICING_VERIFIED_DATE = today → OK, age=0 --------------------------------
run_doctor_freshness_ok() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  touch "$log"; chmod 0600 "$log"
  # Create a tmp cost-models.sh with today's date.
  local today; today=$(date -u +%Y-%m-%d)
  local tmp_models="$d/cost-models.sh"
  cat > "$tmp_models" <<EOF
PRICING_VERIFIED_DATE="$today"
EOF
  local out
  out=$(BATON_EVENT_LOG="$log" \
    BATON_COST_MODELS_PATH="$tmp_models" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "FRESHNESS-OK: OK line with age=0" \
    "echo '$out' | grep -qE 'OK:.*PRICING_VERIFIED_DATE=.*age=0 days'"
  rm -rf "$d"
}
run_doctor_freshness_ok

# --- PRICING_VERIFIED_DATE = 100 days ago → WARNING with re-verify URL --------
run_doctor_freshness_stale() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  touch "$log"; chmod 0600 "$log"
  # Compute a date 100 days ago.
  local stale_date; stale_date=$(date -u -d '100 days ago' +%Y-%m-%d 2>/dev/null \
    || date -u -v -100d +%Y-%m-%d 2>/dev/null)
  local tmp_models="$d/cost-models.sh"
  cat > "$tmp_models" <<EOF
PRICING_VERIFIED_DATE="$stale_date"
EOF
  local out
  out=$(BATON_EVENT_LOG="$log" \
    BATON_COST_MODELS_PATH="$tmp_models" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1)
  assert "FRESHNESS-STALE: WARNING with re-verify" \
    "echo '$out' | grep -qE 'WARNING:.*re-verify'"
  assert "FRESHNESS-STALE: pricing URL present" \
    "echo '$out' | grep -qF 'platform.claude.com/docs'"
  rm -rf "$d"
}
run_doctor_freshness_stale

# --- stale freshness must drive doctor EXIT CODE 1 (not just print) ----------
# Regression (E8 RE-REVIEW-3): the stale-pricing block printed a WARNING but
# did not set WARNED=1, so doctor exited 0 / "summary: ok" while pricing was
# arbitrarily stale - silently defeating L1-AC#2 re-verification for CI callers.
# Prior tests only grepped the WARNING text, never the exit code.
run_doctor_freshness_stale_exitcode() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  touch "$log"; chmod 0600 "$log"
  local stale_date; stale_date=$(date -u -d '100 days ago' +%Y-%m-%d 2>/dev/null \
    || date -u -v -100d +%Y-%m-%d 2>/dev/null)
  local tmp_models="$d/cost-models.sh"
  cat > "$tmp_models" <<EOF
PRICING_VERIFIED_DATE="$stale_date"
EOF
  local out rc
  out=$(BATON_EVENT_LOG="$log" \
    BATON_COST_MODELS_PATH="$tmp_models" \
    PATH="$shim:$PATH" bash "$DOCTOR" 2>&1); rc=$?
  assert "FRESHNESS-STALE-EXIT: doctor exits 1 on stale pricing (got $rc)" \
    "[ '$rc' = '1' ]"
  assert "FRESHNESS-STALE-EXIT: summary not 'ok'" \
    "! echo '$out' | grep -qE 'summary: ok'"
  rm -rf "$d"
}
run_doctor_freshness_stale_exitcode

# --- fresh pricing keeps doctor EXIT CODE 0 (no false positive) -------------
run_doctor_freshness_ok_exitcode() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local shim="$d/bin"; make_stat_shim "$shim"
  touch "$log"; chmod 0600 "$log"
  local today; today=$(date -u +%Y-%m-%d)
  local tmp_models="$d/cost-models.sh"
  cat > "$tmp_models" <<EOF
PRICING_VERIFIED_DATE="$today"
EOF
  # E19 T8 fallout: neutralize doctor's new crontab + statusline backstop
  # checks so a host without those wirings can't drive WARNED=1 → exit 1.
  cat > "$shim/crontab" <<'SH'
#!/bin/bash
[ "$1" = "-l" ] && { echo '*/30 * * * * cleanup-cron-wrapper'; exit 0; }
exit 0
SH
  chmod +x "$shim/crontab"
  cat > "$d/settings.json" <<'SH'
{"statusLine":{"command":"bash $HOME/.claude/assets/baton-pct.sh $SESSION_ID"}}
SH
  local rc
  BATON_EVENT_LOG="$log" \
    BATON_COST_MODELS_PATH="$tmp_models" \
    BATON_DOCTOR_SETTINGS="$d/settings.json" \
    PATH="$shim:$PATH" bash "$DOCTOR" >/dev/null 2>&1; rc=$?
  assert "FRESHNESS-OK-EXIT: doctor exits 0 on fresh pricing (got $rc)" \
    "[ '$rc' = '0' ]"
  rm -rf "$d"
}
run_doctor_freshness_ok_exitcode

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
