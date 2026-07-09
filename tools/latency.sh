#!/usr/bin/env bash
# tools/latency.sh - quantile reporting over hook-events.jsonl.
#
# Sections of the report (each emits only if its source events are present):
#   1. tool_call latency by tool_name (from tool-timing.sh; populated only
#      when BATON_TIMING=1).
#   2. Instrumentation overhead - hook_overhead_ms quantiles across all
#      tool_call events. "What BATON_TIMING=1 is costing you."
#   3. Summarizer-window wall-clock - paired PreToolUse(pending_set=true)
#      with the next PostToolUse carrying a non-empty progress_file_basename.
#      Second resolution (limited by event ts precision).
#   4. Cleanup-hook duration - PostToolUse.duration_ms from checkpoint-write-
#      trigger.sh (the cleanup hook's own self-timing on progress writes).
#
# Args:
#   --since-hours N    Only consider events newer than N hours ago. Default 24.
#   --tool NAME        Restrict tool_call quantiles to a single tool name.
#   --json             Emit JSON instead of human text.
#   --event-log PATH   Override BATON_EVENT_LOG / default path.
#   --include-shards   Include rotated .zst shards alongside the live log.
#   -h | --help        Show this header.
#
# Exit codes:
#   0  output produced (even if some sections empty)
#   2  unrecognised flag or invalid arg
#
# Reads the live $BATON_EVENT_LOG (default
#   $XDG_STATE_HOME/baton/hook-events.jsonl).
# Read-only. No network.
set -uo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"   # CC6

SINCE_HOURS=24
TOOL_FILTER=""
JSON_MODE=0
EVENT_LOG_OVERRIDE=""
INCLUDE_SHARDS=0

show_help() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed -e '$d' -e 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since-hours)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "latency.sh: --since-hours requires a non-negative integer" >&2; exit 2; }
      SINCE_HOURS="$2"; shift 2 ;;
    --tool)
      [[ -n "${2:-}" ]] || { echo "latency.sh: --tool requires a name" >&2; exit 2; }
      TOOL_FILTER="$2"; shift 2 ;;
    --json)
      JSON_MODE=1; shift ;;
    --event-log)
      [[ -n "${2:-}" ]] || { echo "latency.sh: --event-log requires a path" >&2; exit 2; }
      EVENT_LOG_OVERRIDE="$2"; shift 2 ;;
    --include-shards)
      INCLUDE_SHARDS=1; shift ;;
    -h|--help)
      show_help; exit 0 ;;
    *)
      echo "latency.sh: unknown flag '$1'" >&2
      exit 2 ;;
  esac
done

# Resolve event log path.
if [[ -n "$EVENT_LOG_OVERRIDE" ]]; then
  LOG_PATH="$EVENT_LOG_OVERRIDE"
else
  LOG_PATH="$(_cfg::get BATON_EVENT_LOG "${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl")"
fi

# Build the list of input streams (live log + optional rotated shards).
INPUTS_RAW=()
[[ -f "$LOG_PATH" ]] && INPUTS_RAW+=("$LOG_PATH")
if [[ "$INCLUDE_SHARDS" -eq 1 ]]; then
  shopt -s nullglob
  for f in "$LOG_PATH".*.zst; do
    INPUTS_RAW+=("$f")
  done
  shopt -u nullglob
fi

if [[ "${#INPUTS_RAW[@]}" -eq 0 ]]; then
  if [[ "$JSON_MODE" -eq 1 ]]; then
    jq -cn --arg p "$LOG_PATH" '{error:"no event log",path:$p}'
  else
    echo "latency.sh: no event log at $LOG_PATH" >&2
  fi
  exit 0
fi

# Cutoff timestamp (GNU date / BSD date fallback).
SINCE_ISO=$(date -u -d "$SINCE_HOURS hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -v"-${SINCE_HOURS}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || echo "1970-01-01T00:00:00Z")

# Stream all input files (zstdcat for .zst, cat for plain). The trailing cat
# of stdin keeps the pipeline simple downstream - every section re-reads.
stream_events() {
  for f in "${INPUTS_RAW[@]}"; do
    case "$f" in
      *.zst) zstdcat "$f" 2>/dev/null ;;
      *)     cat     "$f" 2>/dev/null ;;
    esac
  done
}

# POSIX quantile awk - same idiom as tools/cost.sh.
quantiles_awk='
  function quant(p,   idx, lo, frac) {
    if (n <= 1) return v[1]
    idx = (n-1)*p + 1
    lo = int(idx)
    if (lo >= n) return v[n]
    frac = idx - lo
    return v[lo] + frac*(v[lo+1]-v[lo])
  }
  { v[NR]=$1+0; s += $1+0 }
  END {
    n=NR
    if (n==0) { print "0\t0\t0\t0\t0\t0\t0\t0\t0"; exit }
    mean = s/n
    printf "%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.2f\n",
      n, v[1], quant(0.25), quant(0.50), quant(0.75), quant(0.95), quant(0.99), v[n], mean
  }
'

# Computes quantiles over stdin's whitespace-separated values.
# Output: tab-separated n min p25 median p75 p95 p99 max mean.
quantiles() {
  LC_ALL=C sort -n | LC_ALL=C awk "$quantiles_awk"
}

# Filter line: keep only events at-or-after the cutoff.
since_filter='select(.ts >= $since)'

# --------------------------------------------------------------------------
# Section 1 + 2: tool_call latency + hook_overhead_ms.
# --------------------------------------------------------------------------
# Extract per-tool durations as "tool_name\tduration_ms" lines.
tool_call_rows=$(stream_events \
  | jq -rR --arg since "$SINCE_ISO" --arg filter "$TOOL_FILTER" '
      (fromjson? // empty)
      | '"$since_filter"'
      | select(.event == "tool_call")
      | select($filter == "" or .data.tool_name == $filter)
      | [(.data.tool_name // "unknown"), (.data.duration_ms // 0), (.data.hook_overhead_ms // 0)]
      | @tsv' \
  2>/dev/null)

# Overall per-tool quantiles (per tool_name).
declare -A TOOL_QUANTS
if [[ -n "$tool_call_rows" ]]; then
  # Unique tool names.
  mapfile -t TOOL_NAMES < <(printf '%s\n' "$tool_call_rows" | awk -F'\t' '{print $1}' | sort -u)
  for tn in "${TOOL_NAMES[@]}"; do
    stats=$(printf '%s\n' "$tool_call_rows" \
            | awk -F'\t' -v t="$tn" '$1==t {print $2}' \
            | quantiles)
    TOOL_QUANTS["$tn"]="$stats"
  done
  # Aggregate (all tools).
  AGG_LATENCY=$(printf '%s\n' "$tool_call_rows" | awk -F'\t' '{print $2}' | quantiles)
  # Overhead - single bucket across all events.
  AGG_OVERHEAD=$(printf '%s\n' "$tool_call_rows" | awk -F'\t' '{print $3}' | quantiles)
else
  TOOL_NAMES=()
  AGG_LATENCY=""
  AGG_OVERHEAD=""
fi

# --------------------------------------------------------------------------
# Section 3: summarizer-window wall-clock (paired PreToolUse → PostToolUse).
# --------------------------------------------------------------------------
# Strategy: extract a chronological stream of just the marker events
# (PreToolUse pending_set=true, PostToolUse with non-empty
# progress_file_basename), one per line as "tag\tts". Then walk it with awk,
# emitting one summarizer_secs per matched pair (skipping orphans).
window_rows=$(stream_events \
  | jq -rR --arg since "$SINCE_ISO" '
      (fromjson? // empty)
      | '"$since_filter"'
      | if (.event == "PreToolUse" and (.data.pending_set == true)) then
          ["P", .ts] | @tsv
        elif (.event == "PostToolUse" and ((.data.progress_file_basename // "") != "")) then
          ["W", .ts] | @tsv
        else empty end' \
  2>/dev/null)

summarizer_secs=$(printf '%s\n' "$window_rows" \
  | awk -F'\t' '
    function isots_to_epoch(s,   y,mo,d,h,mi,se,tm) {
      # 2026-05-16T23:54:07Z → epoch seconds (UTC).
      y  = substr(s, 1, 4)+0
      mo = substr(s, 6, 2)+0
      d  = substr(s, 9, 2)+0
      h  = substr(s,12, 2)+0
      mi = substr(s,15, 2)+0
      se = substr(s,18, 2)+0
      # awk built-in mktime expects local time; convert via env-set TZ=UTC
      # done in awk -v env. Otherwise this approximation drifts by tz offset.
      # Caller invokes with TZ=UTC environment.
      tm = sprintf("%04d %02d %02d %02d %02d %02d", y, mo, d, h, mi, se)
      return mktime(tm)
    }
    /^P\t/ { p_ts = $2; have_p = 1; next }
    /^W\t/ {
      if (have_p) {
        d = isots_to_epoch($2) - isots_to_epoch(p_ts)
        if (d < 0) d = 0
        print d
        have_p = 0
      }
      next
    }
  ' TZ=UTC 2>/dev/null)

# awk's mktime is gawk-specific; on mawk it returns -1. Detect and recompute
# with a shell fallback if needed.
if [[ -n "$window_rows" ]] && [[ -z "$summarizer_secs" || "$summarizer_secs" =~ ^-1 ]]; then
  summarizer_secs=$(printf '%s\n' "$window_rows" | python3 -c "
import sys, datetime as dt
p_ts = None
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line: continue
    tag, _, ts = line.partition('\t')
    if not ts: continue
    t = dt.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp()
    if tag == 'P':
        p_ts = t
    elif tag == 'W' and p_ts is not None:
        d = max(0, int(t - p_ts))
        print(d)
        p_ts = None
" 2>/dev/null)
fi

if [[ -n "$summarizer_secs" ]]; then
  SUMMARIZER_STATS=$(printf '%s\n' "$summarizer_secs" | quantiles)
else
  SUMMARIZER_STATS=""
fi

# --------------------------------------------------------------------------
# Section 4: cleanup-hook duration (PostToolUse.duration_ms).
# --------------------------------------------------------------------------
cleanup_ms=$(stream_events \
  | jq -rR --arg since "$SINCE_ISO" '
      (fromjson? // empty)
      | '"$since_filter"'
      | select(.event == "PostToolUse")
      | select((.data.progress_file_basename // "") != "")
      | (.data.duration_ms // 0)' \
  2>/dev/null)

if [[ -n "$cleanup_ms" ]]; then
  CLEANUP_STATS=$(printf '%s\n' "$cleanup_ms" | quantiles)
else
  CLEANUP_STATS=""
fi

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
emit_stats_human() {
  local label="$1" stats="$2" unit="$3"
  if [[ -z "$stats" ]]; then
    printf '  %-30s (no data)\n' "$label"
    return
  fi
  IFS=$'\t' read -r n mn p25 med p75 p95 p99 mx mean <<<"$stats"
  printf '  %-30s n=%-5s  min=%-5s p25=%-5s med=%-5s p75=%-5s p95=%-5s p99=%-5s max=%-5s mean=%-7s [%s]\n' \
    "$label" "$n" "$mn" "$p25" "$med" "$p75" "$p95" "$p99" "$mx" "$mean" "$unit"
}

emit_stats_json() {
  local stats="$1"
  if [[ -z "$stats" ]]; then
    echo "null"
    return
  fi
  IFS=$'\t' read -r n mn p25 med p75 p95 p99 mx mean <<<"$stats"
  jq -cn \
    --argjson n "$n" --argjson mn "$mn" --argjson p25 "$p25" \
    --argjson med "$med" --argjson p75 "$p75" --argjson p95 "$p95" \
    --argjson p99 "$p99" --argjson mx "$mx" --argjson mean "$mean" \
    '{n:$n, min:$mn, p25:$p25, median:$med, p75:$p75, p95:$p95, p99:$p99, max:$mx, mean:$mean}'
}

if [[ "$JSON_MODE" -eq 1 ]]; then
  # Build per-tool JSON object.
  per_tool_json='{}'
  for tn in "${TOOL_NAMES[@]:-}"; do
    [[ -z "$tn" ]] && continue
    stats_json=$(emit_stats_json "${TOOL_QUANTS[$tn]}")
    per_tool_json=$(jq -c --arg t "$tn" --argjson s "$stats_json" '.[$t]=$s' <<<"$per_tool_json")
  done

  jq -cn \
    --arg log_path "$LOG_PATH" \
    --arg since "$SINCE_ISO" \
    --arg tool_filter "$TOOL_FILTER" \
    --argjson include_shards "$INCLUDE_SHARDS" \
    --argjson tool_call "$(emit_stats_json "$AGG_LATENCY")" \
    --argjson overhead "$(emit_stats_json "$AGG_OVERHEAD")" \
    --argjson summarizer "$(emit_stats_json "$SUMMARIZER_STATS")" \
    --argjson cleanup "$(emit_stats_json "$CLEANUP_STATS")" \
    --argjson per_tool "$per_tool_json" \
    '{
      log_path:$log_path, since:$since, tool_filter:$tool_filter,
      include_shards:($include_shards==1),
      tool_call_aggregate:$tool_call,
      tool_call_per_tool:$per_tool,
      instrumentation_overhead_ms:$overhead,
      summarizer_window_secs:$summarizer,
      cleanup_hook_ms:$cleanup
    }'
  exit 0
fi

# Human output
echo "baton latency report"
echo "  log:        $LOG_PATH"
echo "  since:      $SINCE_ISO ($SINCE_HOURS h ago)"
[[ -n "$TOOL_FILTER" ]] && echo "  tool:       $TOOL_FILTER"
[[ "$INCLUDE_SHARDS" -eq 1 ]] && echo "  shards:     included"
echo ""

echo "Per-tool latency (tool_call events; populated only when BATON_TIMING=1)"
if [[ "${#TOOL_NAMES[@]}" -eq 0 ]]; then
  echo "  (no tool_call events in window - set BATON_TIMING=1 to capture)"
else
  for tn in "${TOOL_NAMES[@]}"; do
    emit_stats_human "$tn" "${TOOL_QUANTS[$tn]}" "ms"
  done
  echo "  ---"
  emit_stats_human "ALL TOOLS" "$AGG_LATENCY" "ms"
fi
echo ""

echo "Instrumentation overhead (tool-timing hook's own wall-clock)"
emit_stats_human "hook_overhead_ms" "$AGG_OVERHEAD" "ms"
echo ""

echo "Summarizer-window wall-clock (PreToolUse pending → PostToolUse progress)"
emit_stats_human "summarizer_secs" "$SUMMARIZER_STATS" "s"
echo "  (note: ts resolution is 1 second; small windows are not resolvable)"
echo ""

echo "Cleanup-hook duration (PostToolUse.duration_ms on progress writes)"
emit_stats_human "cleanup_hook_ms" "$CLEANUP_STATS" "ms"

exit 0
