#!/usr/bin/env bash
# lib/recommend-cost-extract.sh - extract cost-sweep-corpus --json fields for recommend layer.
# All functions accept one argument: path to cost-sweep-corpus JSON output.
# All jq pipelines use // guards - missing/empty inputs return null/empty, never crash.
set -u

# recommend_cost::winner COST_JSON_PATH
#   Returns the arm string (compact|auto-memory|clear-only|none) with min usd_total
#   in the clean subset; returns "null" if clean subset is empty.
recommend_cost::winner() {
  local f="$1"
  jq -r '[.per_arm_per_subset[]? | select(.subset=="clean")] |
    if length == 0 then null
    else min_by(.usd_total | tonumber) | .arm
    end' "$f"
}

# recommend_cost::per_method COST_JSON_PATH
#   Returns a JSON object {arm: {usd_total, session_count}} for the clean subset only.
#   Returns {} when clean subset is empty.
recommend_cost::per_method() {
  local f="$1"
  jq -c '[.per_arm_per_subset[]? | select(.subset=="clean")] |
    if length == 0 then {}
    else map({(.arm): {usd_total: .usd_total, session_count: .session_count}}) | add // {}
    end' "$f"
}

# recommend_cost::typical_best COST_JSON_PATH
#   Returns the .typical_best object {median, mode}; falls back to {median:null,mode:null}.
recommend_cost::typical_best() {
  local f="$1"
  jq -c '.typical_best // {median:null,mode:null}' "$f"
}

# recommend_cost::aggregates COST_JSON_PATH
#   Returns the .aggregates passthrough object; falls back to {} on missing/null.
recommend_cost::aggregates() {
  local f="$1"
  jq -c '.aggregates // {}' "$f"
}
