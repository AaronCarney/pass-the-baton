#!/bin/bash
# Tests for tools/latency.sh - quantile reporting over hook-events.jsonl.
# Covers: empty / missing log, per-tool quantiles, overhead, summarizer-window
# pairing (incl. orphan), cleanup-hook duration, --tool filter, --since-hours
# cutoff, --json shape, --include-shards.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
LATENCY_SH="$REPO_DIR/tools/latency.sh"

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

# Build a tool_call event line on stdout.
make_tool_call() {
  local ts="$1" tool="$2" dur="$3" overhead="${4:-2}"
  jq -cn --arg ts "$ts" --arg tn "$tool" --argjson d "$dur" --argjson o "$overhead" \
    '{schema_version:1, event:"tool_call", ts:$ts,
      data:{tool_name:$tn, duration_ms:$d, hook_overhead_ms:$o,
            workstream:"ws", terminal_hash:"abc123", tool_use_id:"tu_x"}}'
}

# Build a PreToolUse(pending_set) event.
make_pretooluse_pending() {
  local ts="$1"
  jq -cn --arg ts "$ts" \
    '{schema_version:1, event:"PreToolUse", ts:$ts,
      data:{tool_name:"Write", context_pct:28, threshold:28, pending_set:true}}'
}

# Build a PostToolUse with progress_file_basename (closes the summarizer window).
make_progress_write() {
  local ts="$1" dur="${2:-15}"
  jq -cn --arg ts "$ts" --argjson d "$dur" \
    '{schema_version:1, event:"PostToolUse", ts:$ts,
      data:{tool_name:"Write", workstream:"ws", terminal_hash:"abc123",
            progress_file_basename:"progress-ws-abc123.md", duration_ms:$d}}'
}

echo "## tools/latency.sh"

assert "SYNTAX: bash -n passes" "bash -n '$LATENCY_SH' 2>/dev/null"

# --- missing log ------------------------------------------------------------
run_missing_log() {
  local d; d=$(mktemp -d)
  local out err rc
  out=$(bash "$LATENCY_SH" --event-log "$d/nope.jsonl" 2>"$d/err")
  rc=$?
  assert "MISSING: rc=0" "[ '$rc' = '0' ]"
  assert "MISSING: stderr mentions no event log" "grep -q 'no event log' '$d/err'"
  # JSON form
  out=$(bash "$LATENCY_SH" --event-log "$d/nope.jsonl" --json 2>/dev/null)
  assert "MISSING --json: contains error field" "echo '$out' | jq -e '.error == \"no event log\"' >/dev/null 2>&1"
  rm -rf "$d"
}
run_missing_log

# --- empty log: each section reports no data --------------------------------
run_empty_log() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  : > "$log"
  bash "$LATENCY_SH" --event-log "$log" > "$d/out" 2>/dev/null
  assert "EMPTY: tool_call section reports no events" "grep -q 'no tool_call events' '$d/out'"
  assert "EMPTY: cleanup section shows no data" "grep -qE 'cleanup_hook_ms.*no data' '$d/out'"
  rm -rf "$d"
}
run_empty_log

# --- unknown flag exits 2 ---------------------------------------------------
run_unknown_flag() {
  local d; d=$(mktemp -d)
  local rc
  bash "$LATENCY_SH" --bogus 2>/dev/null
  rc=$?
  assert "UNKNOWN-FLAG: rc=2" "[ '$rc' = '2' ]"
  rm -rf "$d"
}
run_unknown_flag

# --- per-tool quantiles ------------------------------------------------------
run_per_tool_quantiles() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # 5 Bash events with durations 10, 20, 30, 40, 50 (median 30, p95 ≈ 48)
  for d_ms in 10 20 30 40 50; do
    make_tool_call "$NOW" Bash "$d_ms" 3 >> "$log"
  done
  # 3 Read events with durations 5, 5, 5 (median 5)
  for _ in 1 2 3; do
    make_tool_call "$NOW" Read 5 2 >> "$log"
  done
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --json 2>/dev/null)
  assert "PER-TOOL: Bash n=5"   "echo '$out' | jq -e '.tool_call_per_tool.Bash.n == 5' >/dev/null 2>&1"
  assert "PER-TOOL: Bash median=30" "echo '$out' | jq -e '.tool_call_per_tool.Bash.median == 30' >/dev/null 2>&1"
  assert "PER-TOOL: Bash max=50" "echo '$out' | jq -e '.tool_call_per_tool.Bash.max == 50' >/dev/null 2>&1"
  assert "PER-TOOL: Read n=3"   "echo '$out' | jq -e '.tool_call_per_tool.Read.n == 3' >/dev/null 2>&1"
  assert "PER-TOOL: Read median=5"  "echo '$out' | jq -e '.tool_call_per_tool.Read.median == 5' >/dev/null 2>&1"
  assert "AGGREGATE: ALL TOOLS n=8" "echo '$out' | jq -e '.tool_call_aggregate.n == 8' >/dev/null 2>&1"
  # Overhead aggregate covers all 8 events
  assert "OVERHEAD: n=8" "echo '$out' | jq -e '.instrumentation_overhead_ms.n == 8' >/dev/null 2>&1"
  rm -rf "$d"
}
run_per_tool_quantiles

# --- summarizer-window pairing ----------------------------------------------
run_summarizer_pairing() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Pair 1: pending at 00:00, write at 00:05 → 5s window
  make_pretooluse_pending "2026-05-16T00:00:00Z" >> "$log"
  make_progress_write     "2026-05-16T00:00:05Z" >> "$log"
  # Pair 2: pending at 01:00, write at 01:30 → 30s window
  make_pretooluse_pending "2026-05-16T01:00:00Z" >> "$log"
  make_progress_write     "2026-05-16T01:00:30Z" >> "$log"
  # Orphan: pending at 02:00 with no matching write (should be skipped)
  make_pretooluse_pending "2026-05-16T02:00:00Z" >> "$log"
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --since-hours 9999 --json 2>/dev/null)
  assert "SUMMARIZER: n=2 (orphan skipped)" "echo '$out' | jq -e '.summarizer_window_secs.n == 2' >/dev/null 2>&1"
  assert "SUMMARIZER: min=5"     "echo '$out' | jq -e '.summarizer_window_secs.min == 5' >/dev/null 2>&1"
  assert "SUMMARIZER: max=30"    "echo '$out' | jq -e '.summarizer_window_secs.max == 30' >/dev/null 2>&1"
  assert "SUMMARIZER: median between min and max" \
    "echo '$out' | jq -e '.summarizer_window_secs.median >= 5 and .summarizer_window_secs.median <= 30' >/dev/null 2>&1"
  rm -rf "$d"
}
run_summarizer_pairing

# --- cleanup-hook duration ---------------------------------------------------
run_cleanup_duration() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  make_progress_write "$NOW" 10 >> "$log"
  make_progress_write "$NOW" 20 >> "$log"
  make_progress_write "$NOW" 30 >> "$log"
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --json 2>/dev/null)
  assert "CLEANUP: n=3"      "echo '$out' | jq -e '.cleanup_hook_ms.n == 3' >/dev/null 2>&1"
  assert "CLEANUP: median=20" "echo '$out' | jq -e '.cleanup_hook_ms.median == 20' >/dev/null 2>&1"
  assert "CLEANUP: max=30"   "echo '$out' | jq -e '.cleanup_hook_ms.max == 30' >/dev/null 2>&1"
  rm -rf "$d"
}
run_cleanup_duration

# --- --tool filter ----------------------------------------------------------
run_tool_filter() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  make_tool_call "$NOW" Bash 100 >> "$log"
  make_tool_call "$NOW" Bash 200 >> "$log"
  make_tool_call "$NOW" Read 50 >> "$log"
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --tool Bash --json 2>/dev/null)
  assert "FILTER --tool=Bash: aggregate n=2" "echo '$out' | jq -e '.tool_call_aggregate.n == 2' >/dev/null 2>&1"
  assert "FILTER --tool=Bash: Read NOT in per-tool" "echo '$out' | jq -e '.tool_call_per_tool.Read == null' >/dev/null 2>&1"
  assert "FILTER --tool=Bash: Bash IS in per-tool" "echo '$out' | jq -e '.tool_call_per_tool.Bash.n == 2' >/dev/null 2>&1"
  rm -rf "$d"
}
run_tool_filter

# --- --since-hours cutoff excludes old events --------------------------------
run_since_cutoff() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # An "old" event from 2024 - should be excluded with default --since-hours=24.
  make_tool_call "2024-01-01T00:00:00Z" Bash 9999 >> "$log"
  # A "recent" event from now.
  make_tool_call "$NOW" Bash 100 >> "$log"
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --since-hours 24 --json 2>/dev/null)
  assert "SINCE: only 1 event after default cutoff" "echo '$out' | jq -e '.tool_call_aggregate.n == 1' >/dev/null 2>&1"
  # Now bump cutoff to include the old one.
  out=$(bash "$LATENCY_SH" --event-log "$log" --since-hours 200000 --json 2>/dev/null)
  assert "SINCE: --since-hours=200000 includes old" "echo '$out' | jq -e '.tool_call_aggregate.n == 2' >/dev/null 2>&1"
  rm -rf "$d"
}
run_since_cutoff

# --- --since-hours invalid → exit 2 -----------------------------------------
run_since_invalid() {
  local rc
  bash "$LATENCY_SH" --since-hours foo 2>/dev/null
  rc=$?
  assert "SINCE-INVALID: rc=2" "[ '$rc' = '2' ]"
}
run_since_invalid

# --- JSON shape includes all top-level keys ---------------------------------
run_json_shape() {
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  make_tool_call "$NOW" Bash 100 >> "$log"
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --json 2>/dev/null)
  assert "JSON-SHAPE: parses as JSON" "echo '$out' | jq -e '.' >/dev/null 2>&1"
  assert "JSON-SHAPE: has log_path"               "echo '$out' | jq -e '.log_path' >/dev/null 2>&1"
  assert "JSON-SHAPE: has since"                  "echo '$out' | jq -e '.since' >/dev/null 2>&1"
  assert "JSON-SHAPE: has tool_call_aggregate"    "echo '$out' | jq -e '.tool_call_aggregate' >/dev/null 2>&1"
  assert "JSON-SHAPE: has tool_call_per_tool"     "echo '$out' | jq -e '.tool_call_per_tool' >/dev/null 2>&1"
  assert "JSON-SHAPE: has instrumentation_overhead_ms" "echo '$out' | jq -e '.instrumentation_overhead_ms' >/dev/null 2>&1"
  assert "JSON-SHAPE: has summarizer_window_secs" "echo '$out' | jq -e 'has(\"summarizer_window_secs\")' >/dev/null 2>&1"
  assert "JSON-SHAPE: has cleanup_hook_ms"        "echo '$out' | jq -e 'has(\"cleanup_hook_ms\")' >/dev/null 2>&1"
  rm -rf "$d"
}
run_json_shape

# --- --include-shards reads .zst when zstd available ------------------------
run_include_shards() {
  command -v zstd >/dev/null 2>&1 || { echo "  SKIP  shards: zstd not installed"; return; }
  command -v zstdcat >/dev/null 2>&1 || { echo "  SKIP  shards: zstdcat not installed"; return; }
  local d; d=$(mktemp -d)
  local log="$d/events.jsonl"
  local NOW; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Live log has 1 event
  make_tool_call "$NOW" Bash 100 >> "$log"
  # Rotated shard has 2 events
  local shard_raw="$d/events.jsonl.20260516.jsonl"
  make_tool_call "$NOW" Bash 200 >> "$shard_raw"
  make_tool_call "$NOW" Bash 300 >> "$shard_raw"
  zstd -q --rm "$shard_raw"     # produces $shard_raw.zst
  mv "${shard_raw}.zst" "$log.20260516.zst"
  # Without --include-shards
  local out; out=$(bash "$LATENCY_SH" --event-log "$log" --json 2>/dev/null)
  assert "SHARDS: without flag → n=1 (live only)" "echo '$out' | jq -e '.tool_call_aggregate.n == 1' >/dev/null 2>&1"
  out=$(bash "$LATENCY_SH" --event-log "$log" --include-shards --json 2>/dev/null)
  assert "SHARDS: with flag → n=3 (live + shard)" "echo '$out' | jq -e '.tool_call_aggregate.n == 3' >/dev/null 2>&1"
  rm -rf "$d"
}
run_include_shards

# --- help flag --------------------------------------------------------------
run_help() {
  local d; d=$(mktemp -d)
  bash "$LATENCY_SH" --help > "$d/help" 2>/dev/null
  assert "HELP: mentions --since-hours" "grep -q 'since-hours' '$d/help'"
  assert "HELP: mentions --tool"        "grep -q -- '--tool' '$d/help'"
  assert "HELP: mentions --json"        "grep -q -- '--json' '$d/help'"
  rm -rf "$d"
}
run_help

echo ""
echo "$PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
