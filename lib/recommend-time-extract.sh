#!/usr/bin/env bash
# lib/recommend-time-extract.sh - extract time-winner + per-method map from
# time-to-complete-corpus.sh --json output. CI field is passed through
# when present (--rigor workshop|mlsys).

set -uo pipefail
export LC_ALL=C

command -v jq >/dev/null || { printf 'recommend-time-extract: jq required\n' >&2; return 2 2>/dev/null || exit 2; }

# recommend_time::winner TIME_JSON_PATH
# Returns the method-id with minimum median_seconds, or "null" if no data.
recommend_time::winner() {
  local time_json="$1"
  jq -r '(.per_method // {})
    | to_entries
    | map(select(.value.median_seconds != null))
    | if length == 0 then "null"
      else min_by(.value.median_seconds) | .key
      end' "$time_json"
}

# recommend_time::per_method TIME_JSON_PATH
# Returns the per_method object with ci preserved if present. Defaults to {}.
recommend_time::per_method() {
  local time_json="$1"
  jq -c '.per_method // {}' "$time_json"
}
