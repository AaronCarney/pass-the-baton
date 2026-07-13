#!/usr/bin/env bash
# lib/recommend-outcome-extract.sh - parse outcome-proxy-rollup.sh --json output.
# Producer emits: .headline (method→subkind→aggregate-block) + .decomposition.
# No .per_method / .score / .post_e16_days keys - consumer derives those.
# All functions use // guards - missing/empty inputs return null/empty, never crash.
set -u

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/eventlog.sh"

# Outcome-quality look-back window (days); knob-tunable, default 30.
outcome_window_days() { printf '%s' "${BATON_OUTCOME_WINDOW_DAYS:-30}"; }

# recommend_outcome::winner OUTCOME_JSON_PATH
#   PRIMARY rule: method with max .headline[m].code_execution.success_rate (non-null).
#   FALLBACK rule: method with max sum-over-subkinds-of-.n when no method has success_rate.
#   TIE-BREAK (both rules): lexicographically-FIRST method-id.
#   NOTE: jq max_by returns LAST max in input order, so sort_by(.key)|reverse|max_by(...)
#   yields lex-FIRST winner on ties.
#   Returns "null" when .headline is empty.
recommend_outcome::winner() {
  local f="$1"
  jq -r '
    . as $root |
    # PRIMARY: methods with code_execution.success_rate non-null
    [(.headline // {}) | to_entries[] | select(.value.code_execution.success_rate != null)]
    | if length > 0 then
        sort_by(.key) | reverse | max_by(.value.code_execution.success_rate) | .key
      else
        # FALLBACK: max sum-of-.n across all subkinds (per-element // 0 binding)
        [($root.headline // {}) | to_entries[]
          | {key: .key, n_total: ([.value[]? | (.n // 0)] | add // 0)}]
        | if length == 0 then null
          else sort_by(.key) | reverse | max_by(.n_total) | .key
          end
      end
  ' "$f"
}

# recommend_outcome::per_method OUTCOME_JSON_PATH
#   Returns the .headline object verbatim; {} when absent.
recommend_outcome::per_method() {
  local f="$1"
  jq -c '.headline // {}' "$f"
}

# recommend_outcome::post_e16_days EVENTS_LOG
#   Computes integer days from earliest outcome_proxy event ts to today.
#   Honors CC_NOW env-var: today_iso="${CC_NOW:-$(date -u +%Y-%m-%d)}".
#   Returns empty string if no outcome_proxy events found.
recommend_outcome::post_e16_days() {
  local events_log="$1"
  local today_iso="${CC_NOW:-$(date -u +%Y-%m-%d)}"
  local ts_min
  ts_min=$(eventlog::stream "$events_log" | jq -rs '[.[] | select(.event=="outcome_proxy") | .ts] | min // empty')
  if [[ -z "$ts_min" ]]; then
    echo ""
    return 0
  fi
  local earliest_date="${ts_min%T*}"
  # Compute day difference using date arithmetic
  local d0 d1
  d0=$(date -u -d "$earliest_date" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$earliest_date" +%s)
  d1=$(date -u -d "$today_iso" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$today_iso" +%s)
  echo $(( (d1 - d0) / 86400 ))
}

# recommend_outcome::is_insufficient DAYS
#   Prints "true" if DAYS < outcome_window_days (insufficient data), "false" otherwise.
#   DAYS == window → "false" (closed-upper inclusive: a full window is sufficient).
recommend_outcome::is_insufficient() {
  local days="$1"
  if (( days < $(outcome_window_days) )); then
    echo "true"
  else
    echo "false"
  fi
}
