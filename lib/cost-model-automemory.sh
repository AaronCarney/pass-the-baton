#!/usr/bin/env bash
# lib/cost-model-automemory.sh - auto-memory arm cost model (Anthropic v2.1.59+).
# Pure: no I/O, no jq. Depends on lib/cost-models.sh (must be sourced first).
# DR-2 / B3 formulas.
set -u

if ! declare -f cost_models::price >/dev/null 2>&1; then
  echo "lib/cost-model-automemory.sh: source lib/cost-models.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# cost_model_automemory::event_cost <model> <automemory_tokens> first|within-ttl|post-compact
#   Emits USD float (6 decimals) for the auto-memory surcharge contributed by
#   ONE event/turn-context of automemory_tokens prefix.
#   - first: pays cache_write_5m (one-shot per session)
#   - within-ttl: pays cache_read (every turn within 5-min TTL window)
#   - post-compact: pays 0 (prefix survives /compact, no re-write)
cost_model_automemory::event_cost() {
  local model="$1" tokens="$2" mode="$3"
  if ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
    echo "cost_model_automemory: tokens must be non-negative integer (got: $tokens)" >&2
    return 1
  fi
  local rate
  case "$mode" in
    first)
      rate="$(cost_models::price "$model" cache_write_5m)" || return 2 ;;
    within-ttl)
      rate="$(cost_models::price "$model" cache_read)" || return 2 ;;
    post-compact)
      printf '%s\n' '0.000000'; return 0 ;;
    *)
      echo "cost_model_automemory: mode must be first|within-ttl|post-compact (got: $mode)" >&2
      return 1 ;;
  esac
  LC_ALL=C awk -v t="$tokens" -v r="$rate" \
    'BEGIN{ printf "%.6f\n", (t * r) / 1000000.0 }'
}
