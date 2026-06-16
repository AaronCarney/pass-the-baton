#!/usr/bin/env bash
# lib/cost-model-none.sh - no-management baseline cost model.
# Pure: no I/O, no jq. Depends on lib/cost-models.sh (must be sourced first).
# L0 A2: monotonic context growth; every turn billed at full base_in.
set -u

if ! declare -f cost_models::price >/dev/null 2>&1; then
  echo "lib/cost-model-none.sh: source lib/cost-models.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# cost_model_none::turn_cost <model> <context_in_tokens> <output_tokens>
#   USD float for a single turn billed at full base_in (no cache benefit).
cost_model_none::turn_cost() {
  local model="$1" ctx="$2" out="$3"
  if ! [[ "$ctx" =~ ^[0-9]+$ ]] || ! [[ "$out" =~ ^[0-9]+$ ]]; then
    echo "cost_model_none: ctx and out must be non-negative integers (got: $ctx $out)" >&2
    return 1
  fi
  local r_in r_out
  r_in="$(cost_models::price "$model" base_in)" || return 2
  r_out="$(cost_models::price "$model" base_out)" || return 2
  LC_ALL=C awk -v c="$ctx" -v o="$out" -v rin="$r_in" -v rout="$r_out" \
    'BEGIN{ printf "%.6f\n", (c*rin + o*rout) / 1000000.0 }'
}

# cost_model_none::trajectory_cost <model> - reads TSV (ctx<TAB>out) on stdin,
# emits total USD as 6-decimal float. Empty stream → 0.000000.
cost_model_none::trajectory_cost() {
  local model="$1"
  local r_in r_out
  r_in="$(cost_models::price "$model" base_in)" || return 2
  r_out="$(cost_models::price "$model" base_out)" || return 2
  LC_ALL=C awk -F'\t' -v rin="$r_in" -v rout="$r_out" \
    'BEGIN{ total = 0 }
     { total += ($1+0)*rin + ($2+0)*rout }
     END{ printf "%.6f\n", total / 1000000.0 }'
}
