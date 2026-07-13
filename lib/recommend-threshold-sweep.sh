#!/usr/bin/env bash
# lib/recommend-threshold-sweep.sh - optimal-threshold sweep with bootstrap CI.
# Algorithm (c-021): enumerate producer-emitted keys from .aggregates (even-step 10,12,...,50),
# compute savings vs baseline '22', pick argmax (tie-break: smallest T), surface CI via BCa.
set -uo pipefail
_SWEEP_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stats-bootstrap.sh
source "$_SWEEP_SD/stats-bootstrap.sh"

# recommend_threshold::sweep COST_JSON_PATH
# Outputs JSON: {argmax, candidates:[{threshold,projected_median,savings_vs_22}],
#                savings_vs_22_at_argmax, ci:{lower,upper}|null}
recommend_threshold::sweep() {
  local cost_json="${1:?usage: recommend_threshold::sweep COST_JSON_PATH}"

  # Enumerate producer-emitted numeric keys (drop 'never'), sorted ascending
  local keys_json
  keys_json=$(jq -r '.aggregates | keys | map(select(test("^[0-9]+$"))) | map(tonumber) | sort | @json' \
    "$cost_json" 2>/dev/null) || keys_json='[]'

  local n_keys
  n_keys=$(printf '%s' "$keys_json" | jq 'length')

  # No keys or no baseline '22' → null result
  local baseline_median
  baseline_median=$(jq -r '.aggregates["22"].median // empty' "$cost_json" 2>/dev/null) || baseline_median=''

  if [ "$n_keys" -eq 0 ] || [ -z "$baseline_median" ]; then
    printf '{"argmax":null,"candidates":[],"savings_vs_22_at_argmax":null,"ci":null}\n'
    return 0
  fi

  # Build candidates array: [{threshold, projected_median, savings_vs_22}]
  local candidates_json
  candidates_json=$(jq --argjson keys "$keys_json" --arg baseline "$baseline_median" '
    . as $root |
    [$keys[] | . as $t | $t | tostring | . as $tstr |
      {
        threshold: $t,
        projected_median: ($root.aggregates[$tstr].median),
        savings_vs_22: (($baseline | tonumber) - ($root.aggregates[$tstr].median))
      }
    ]
  ' "$cost_json")

  # Pick argmax savings (tie-break: smallest T - keys already sorted ascending so first max wins)
  local argmax savings_at_argmax
  argmax=$(printf '%s' "$candidates_json" | jq '
    reduce .[] as $c (null;
      if . == null then $c
      elif $c.savings_vs_22 > .savings_vs_22 then $c
      else .
      end
    ) | .threshold
  ')
  savings_at_argmax=$(printf '%s' "$candidates_json" | jq "
    map(select(.threshold == $argmax)) | .[0].savings_vs_22
  ")

  # CI via BCa over per-transcript per_threshold[argmax] values
  local argmax_str="$argmax"
  local ci_json='null'
  local transcript_count
  transcript_count=$(jq '.transcripts | length' "$cost_json" 2>/dev/null) || transcript_count=0

  if [ "$transcript_count" -gt 0 ]; then
    local tmp_vals
    tmp_vals=$(mktemp /tmp/sweep-bca-XXXXXX.jsonl)
    jq -r --arg t "$argmax_str" '.transcripts[].per_threshold[$t] | select(. != null)' \
      "$cost_json" > "$tmp_vals" 2>/dev/null
    local val_count
    val_count=$(wc -l < "$tmp_vals" | tr -d ' ')
    if [ "$val_count" -gt 1 ]; then
      local bca_out
      bca_out=$(SEED="${SEED:-$STATS_DEFAULT_SEED}" stats_bootstrap::bca "$tmp_vals" 2>/dev/null) || bca_out=''
      if [ -n "$bca_out" ]; then
        ci_json=$(printf '%s' "$bca_out" | jq '{lower: .ci_lower, upper: .ci_upper}')
      fi
    fi
    rm -f "$tmp_vals"
  fi

  # Emit result
  printf '%s' "$candidates_json" | jq \
    --argjson argmax "$argmax" \
    --argjson sav "$savings_at_argmax" \
    --argjson ci "$ci_json" \
    '{"argmax": $argmax, "candidates": ., "savings_vs_22_at_argmax": $sav, "ci": $ci}'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  recommend_threshold::sweep "$@"
fi
