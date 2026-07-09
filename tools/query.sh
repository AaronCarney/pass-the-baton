#!/bin/bash
# tools/query.sh - baton event-log SQL query (E7-T5).
#
# Wraps DuckDB's read_json_auto over the live hook-events.jsonl plus rotated
# .jsonl.zst shards, exposing them as a single view named `events`.
#
# Usage:
#   bash tools/query.sh "SELECT event, COUNT(*) FROM events GROUP BY event"
#
# Behavior:
#   - Resolves the live log from $BATON_EVENT_LOG (default:
#     $XDG_STATE_HOME/baton/hook-events.jsonl).
#   - Globs rotated shards: <live>.*.zst (e.g. hook-events.jsonl.1.zst).
#   - If duckdb is not on PATH: actionable stderr + exit 2.
#   - If no log files exist: "no events logged yet" on stderr + exit 0.
#   - User SQL is passed positionally to duckdb (NEVER interpolated into the
#     view definition).
# No network. Read-only.
set -u

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"   # CC6

USER_SQL="${1:-}"

if ! command -v duckdb >/dev/null 2>&1; then
  echo "baton query: duckdb not on PATH; install via your package manager (apt install duckdb / brew install duckdb)" >&2
  exit 2
fi

default_event_log() {
  local base="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
  echo "$base/hook-events.jsonl"
}
LIVE_LOG="$(_cfg::get BATON_EVENT_LOG "$(default_event_log)")"

INPUTS=()
[ -e "$LIVE_LOG" ] && INPUTS+=("$LIVE_LOG")
shopt -s nullglob
for f in "$LIVE_LOG".*.zst; do
  INPUTS+=("$f")
done
shopt -u nullglob

if [ "${#INPUTS[@]}" -eq 0 ]; then
  echo "no events logged yet" >&2
  exit 0
fi

# Build a single-quoted, comma-joined list of input paths. Single quotes inside
# paths get doubled. Paths are operator data (config / install layout), not
# untrusted input.
QUOTED=""
for f in "${INPUTS[@]}"; do
  esc=${f//\'/\'\'}
  if [ -z "$QUOTED" ]; then
    QUOTED="'$esc'"
  else
    QUOTED="$QUOTED, '$esc'"
  fi
done

# ignore_errors=true tolerates malformed lines (NUL/blank, CC20) - note it also
# silently drops rows DuckDB can't parse into the inferred schema (schema drift),
# not only the corrupt lines.
VIEW_SQL="CREATE OR REPLACE VIEW events AS SELECT * FROM read_json_auto([${QUOTED}], format='newline_delimited', union_by_name=true, ignore_errors=true);"

# The view definition does not embed user input. User SQL runs AFTER the view
# is locked in (schema-stable). We still pass it via -c rather than splicing.
if [ -z "$USER_SQL" ]; then
  exec duckdb -c "$VIEW_SQL"
fi

exec duckdb -c "$VIEW_SQL $USER_SQL"
