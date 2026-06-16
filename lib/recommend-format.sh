#!/usr/bin/env bash
# lib/recommend-format.sh - human + JSON output renderer for recommend pipeline.
# Usage: recommend::format MODE < aggregate.json
#   MODE: human | json
set -uo pipefail

# recommend::format MODE
# Reads aggregate JSON from stdin; emits human prose or JSON evidence dump.
recommend::format() {
  local mode="${1:-human}"
  local agg
  agg=$(cat)

  if [[ "$mode" == "json" ]]; then
    printf '%s' "$agg" | jq .
    return
  fi

  # ── Human mode ──────────────────────────────────────────────────────────────
  local session_count win_from win_to
  session_count=$(printf '%s' "$agg" | jq -r '.session_count')
  win_from=$(printf '%s' "$agg" | jq -r '.window.from')
  win_to=$(printf '%s' "$agg" | jq -r '.window.to')

  # Days inclusive: (to_epoch - from_epoch)/86400 + 1
  local from_epoch to_epoch days
  from_epoch=$(date -d "$win_from" +%s 2>/dev/null || echo 0)
  to_epoch=$(date -d "$win_to" +%s 2>/dev/null || echo 0)
  days=$(( (to_epoch - from_epoch) / 86400 + 1 ))

  printf 'Recommendation based on %s sessions over %s days.\n' "$session_count" "$days"

  local cost_winner time_winner outcome_winner
  cost_winner=$(printf '%s' "$agg" | jq -r '.winners.cost // empty')
  time_winner=$(printf '%s' "$agg" | jq -r '.winners.time // empty')
  outcome_winner=$(printf '%s' "$agg" | jq -r '.winners.outcome // empty')

  printf 'Cost-optimal method: %s.\n' "${cost_winner:-unknown}"
  printf 'Time-optimal method: %s.\n' "${time_winner:-unknown}"

  # Outcome: winner or insufficient-data literal
  local outcome_insufficient post_e16_days
  outcome_insufficient=$(printf '%s' "$agg" | jq -r '.caveats.outcome_data_insufficient')
  post_e16_days=$(printf '%s' "$agg" | jq -r '.window.post_e16_days // 0')

  if [[ "$outcome_insufficient" == "true" ]]; then
    local days_needed=$(( 30 - post_e16_days ))
    printf 'Outcome-quality recommendation: insufficient data; %s more days needed.\n' "$days_needed"
  else
    printf 'Outcome-quality method: %s.\n' "${outcome_winner:-unknown}"
  fi

  # Threshold recommendation
  local argmax
  argmax=$(printf '%s' "$agg" | jq -r '.threshold_sweep.argmax // empty')
  if [[ -n "$argmax" ]] && [[ "$argmax" != "null" ]]; then
    printf 'Recommended BATON_PCT_THRESHOLD: %s (current default: 23).\n' "$argmax"
  fi

  # Caveats
  local data_age_crossing no_sig_diff
  data_age_crossing=$(printf '%s' "$agg" | jq -r '.caveats.data_age_crossing')
  no_sig_diff=$(printf '%s' "$agg" | jq -r '.caveats.no_significant_difference')

  if [[ "$data_age_crossing" == "true" ]]; then
    local crossing_models
    crossing_models=$(printf '%s' "$agg" | jq -r '.caveats.crossings[] | .model' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    printf 'Caveat: telemetry window crosses model release boundary (%s); cost/time comparisons may mix pricing eras.\n' "$crossing_models"
  fi

  if [[ "$no_sig_diff" == "true" ]]; then
    printf 'Caveat: no significant difference detected between methods in paired comparison.\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  recommend::format "$@"
fi
