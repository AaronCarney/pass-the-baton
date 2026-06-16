#!/bin/bash
# Unit tests for tools/query.sh (E7-T5).
# Generates fixtures via envelope::emit (NOT hand-rolled JSON) to keep query
# output gated on the real envelope schema.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
QUERY="$REPO_DIR/tools/query.sh"
ENVELOPE="$HOOKS_DIR/lib/envelope.sh"

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

# Emit N envelope-shaped records into $BATON_EVENT_LOG.
# Uses event names and tool_name/duration_ms fields the L2 tests assert on.
emit_records() {
  local n="$1"
  ( set +u
    export BATON_COLLECT=1
    # shellcheck source=/dev/null
    source "$ENVELOPE"
    local i
    for ((i=0; i<n; i++)); do
      local ev tool dur
      if (( i % 2 == 0 )); then ev="PreToolUse"; tool="Read"; dur=$((10 + i))
      else                       ev="PostToolUse"; tool="Edit"; dur=$((100 + i))
      fi
      envelope::emit "$ev" "$(printf '{"tool_name":"%s","duration_ms":%d}' "$tool" "$dur")"
    done
  )
}

have_duckdb() { command -v duckdb >/dev/null 2>&1; }
have_zstd()   { command -v zstd   >/dev/null 2>&1; }

echo "## tools/query.sh"

# --- 1. Missing-duckdb path: actionable stderr, exit 2 ----------------------
run_missing_duckdb() {
  local d; d=$(mktemp -d)
  local shim="$d/bin"; mkdir -p "$shim"
  # Build a PATH that has the basics but NOT duckdb.
  # We can't trust real PATH (might have duckdb), so synthesize a minimal one
  # using the directories holding the binaries query.sh actually needs.
  local need_bins=(bash printf cat ls dirname basename mktemp grep awk sed tail head jq stat date)
  for b in "${need_bins[@]}"; do
    local p; p=$(command -v "$b" 2>/dev/null) || continue
    ln -sf "$p" "$shim/$b" 2>/dev/null || cp "$p" "$shim/$b" 2>/dev/null
  done
  local log="$d/hook-events.jsonl"
  : > "$log"
  local out err rc
  out=$(PATH="$shim" BATON_EVENT_LOG="$log" bash "$QUERY" "SELECT 1" 2>"$d/err")
  rc=$?
  err=$(cat "$d/err")
  assert "MISS-DUCKDB: exit code 2" "[ $rc -eq 2 ]"
  assert "MISS-DUCKDB: exact stderr message present" \
    "echo \"\$err\" | grep -qF 'baton query: duckdb not on PATH; install via your package manager (apt install duckdb / brew install duckdb)'"
  assert "MISS-DUCKDB: stdout empty" "[ -z \"\$out\" ]"
  rm -rf "$d"
}
run_missing_duckdb

# --- 2. Missing-log path: exit 0 + 'no events logged yet' on stderr --------
run_missing_log() {
  local d; d=$(mktemp -d)
  local log="$d/does-not-exist.jsonl"
  local out err rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" "SELECT COUNT(*) FROM events" 2>"$d/err")
  rc=$?
  err=$(cat "$d/err")
  assert "MISS-LOG: exit code 0" "[ $rc -eq 0 ]"
  assert "MISS-LOG: stderr says 'no events logged yet'" \
    "echo \"\$err\" | grep -qF 'no events logged yet'"
  assert "MISS-LOG: stdout empty" "[ -z \"\$out\" ]"
  rm -rf "$d"
}
run_missing_log

if ! have_duckdb; then
  echo ""
  echo "SKIP: duckdb not on PATH; remaining cases require it."
  echo "Results: $PASSED passed, $FAILED failed"
  [ "$FAILED" -gt 0 ] && exit 1 || exit 0
fi

# --- 3. Live-only fixture: COUNT(*) FROM events == 10 ----------------------
run_count_10_live() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 10
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT COUNT(*)::BIGINT AS n FROM events" 2>"$d/err")
  rc=$?
  assert "LIVE-10: exit 0" "[ $rc -eq 0 ]"
  assert "LIVE-10: stdout contains 10" "echo \"\$out\" | grep -qE '\\b10\\b'"
  rm -rf "$d"
}
run_count_10_live

# --- 4. Mixed-shard fixture: 5 live + 5 in .jsonl.zst, COUNT(*) == 10 ------
run_count_10_mixed_shards() {
  if ! have_zstd; then
    echo "  SKIP  MIXED-10: zstd not on PATH"
    return 0
  fi
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  # First 5 → live
  BATON_EVENT_LOG="$log" emit_records 5
  # Next 5 → a temp file, then compressed to a rotated shard
  local rotated="$d/hook-events.jsonl.1"
  BATON_EVENT_LOG="$rotated" emit_records 5
  zstd -q -f "$rotated" -o "$rotated.zst"
  rm -f "$rotated"
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT COUNT(*)::BIGINT AS n FROM events" 2>"$d/err")
  rc=$?
  assert "MIXED-10: exit 0" "[ $rc -eq 0 ]"
  assert "MIXED-10: stdout contains 10" "echo \"\$out\" | grep -qE '\\b10\\b'"
  rm -rf "$d"
}
run_count_10_mixed_shards

# --- 5. PreToolUse filter returns only PreToolUse rows ---------------------
run_pretool_filter() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 10
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT event FROM events WHERE event='PreToolUse'" 2>"$d/err")
  rc=$?
  assert "FILTER-PRE: exit 0" "[ $rc -eq 0 ]"
  assert "FILTER-PRE: PreToolUse appears" "echo \"\$out\" | grep -q 'PreToolUse'"
  assert "FILTER-PRE: PostToolUse absent" "! echo \"\$out\" | grep -q 'PostToolUse'"
  rm -rf "$d"
}
run_pretool_filter

# --- 6. data->>'tool_name' access works ------------------------------------
run_json_arrow_access() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 4
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT data->>'tool_name' AS t FROM events" 2>"$d/err")
  rc=$?
  assert "JSON-ARROW: exit 0" "[ $rc -eq 0 ]"
  assert "JSON-ARROW: Read appears in output" "echo \"\$out\" | grep -q 'Read'"
  assert "JSON-ARROW: Edit appears in output" "echo \"\$out\" | grep -q 'Edit'"
  rm -rf "$d"
}
run_json_arrow_access

# --- 7. duration_ms::BIGINT cast works -------------------------------------
run_bigint_cast() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 6
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT (data->>'duration_ms')::BIGINT AS d FROM events ORDER BY d" 2>"$d/err")
  rc=$?
  assert "BIGINT-CAST: exit 0" "[ $rc -eq 0 ]"
  # Smallest emitted is duration_ms=10 (i=0). Largest is 100+5=105 (i=5, odd).
  assert "BIGINT-CAST: min value 10 present" "echo \"\$out\" | grep -qE '\\b10\\b'"
  assert "BIGINT-CAST: max value 105 present" "echo \"\$out\" | grep -qE '\\b105\\b'"
  rm -rf "$d"
}
run_bigint_cast

# --- 8. Invalid SQL: non-zero exit, duckdb error to stderr -----------------
run_invalid_sql() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 3
  local out err rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" "SELEC bogus FRM events" 2>"$d/err")
  rc=$?
  err=$(cat "$d/err")
  assert "INVALID-SQL: non-zero exit" "[ $rc -ne 0 ]"
  assert "INVALID-SQL: duckdb error on stderr" \
    "[ -n \"\$err\" ] && (echo \"\$err\" | grep -qiE 'error|parser|syntax|near')"
  rm -rf "$d"
}
run_invalid_sql

# --- 9. View name is exactly 'events' (not events1, evt, etc.) -------------
run_view_name_events() {
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  BATON_EVENT_LOG="$log" emit_records 2
  # Reference an alternate name and assert it does NOT resolve.
  local err rc
  BATON_EVENT_LOG="$log" bash "$QUERY" "SELECT COUNT(*) FROM evnts" >"$d/out" 2>"$d/err"
  rc=$?
  err=$(cat "$d/err")
  assert "VIEW-NAME: 'evnts' is NOT a defined view (errors)" "[ $rc -ne 0 ]"
  assert "VIEW-NAME: error message mentions evnts" \
    "echo \"\$err\" | grep -qE 'evnts|catalog|not found|does not exist'"
  # And the canonical name DOES resolve.
  BATON_EVENT_LOG="$log" bash "$QUERY" "SELECT COUNT(*) FROM events" >"$d/out2" 2>"$d/err2"
  local rc2=$?
  assert "VIEW-NAME: 'events' resolves (exit 0)" "[ $rc2 -eq 0 ]"
  rm -rf "$d"
}
run_view_name_events

# --- 10. SQL injection safety: user SQL passed positionally ----------------
# The script must build the view definition without interpolating $1 into it.
# Static check on the source file is the strongest signal here.
run_no_sql_interpolation() {
  assert "NO-INTERP: view definition does not embed \$1/\$USER_SQL" \
    "! grep -E 'CREATE OR REPLACE VIEW events.*\\\$(1|USER_SQL|QUERY|SQL)' '$QUERY'"
  assert "NO-INTERP: script references read_json_auto exactly" \
    "grep -q 'read_json_auto' '$QUERY'"
  assert "NO-INTERP: script uses union_by_name=true" \
    "grep -q 'union_by_name=true' '$QUERY'"
}
run_no_sql_interpolation

# --- 11. Rotated-only edge case: no live file, only .jsonl.zst -------------
run_rotated_only() {
  if ! have_zstd; then
    echo "  SKIP  ROTATED-ONLY: zstd not on PATH"
    return 0
  fi
  local d; d=$(mktemp -d)
  local log="$d/hook-events.jsonl"
  local rotated="$d/hook-events.jsonl.7"
  BATON_EVENT_LOG="$rotated" emit_records 4
  zstd -q -f "$rotated" -o "$rotated.zst"
  rm -f "$rotated"
  # Live file does NOT exist.
  local out rc
  out=$(BATON_EVENT_LOG="$log" bash "$QUERY" \
    "SELECT COUNT(*)::BIGINT AS n FROM events" 2>"$d/err")
  rc=$?
  assert "ROTATED-ONLY: exit 0" "[ $rc -eq 0 ]"
  assert "ROTATED-ONLY: stdout contains 4" "echo \"\$out\" | grep -qE '\\b4\\b'"
  rm -rf "$d"
}
run_rotated_only

# --- 12. No network primitives in source -----------------------------------
run_no_network() {
  assert "NO-NET: source has no curl/wget/nc/dev-tcp references" \
    "! grep -rE 'curl|wget|nc |/dev/tcp' '$QUERY'"
}
run_no_network

# --- 13. Static checks for the duckdb-missing error string -----------------
run_duckdb_missing_string() {
  assert "DUCKDB-STR: source contains 'duckdb not on PATH'" \
    "grep -q 'duckdb not on PATH' '$QUERY'"
}
run_duckdb_missing_string

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
