#!/usr/bin/env bash
# lib/gamma-bands.sh - MSM-Γ sensitivity bands (B11)
# Bennett-Kallus-Oprescu conservative approximation: [C/Γ, C·Γ] per arm.
# Pure helpers; no exec on source.

command -v jq >/dev/null || { printf 'lib/gamma-bands.sh: jq not found in PATH\n' >&2; return 2 2>/dev/null || exit 2; }

# gamma_bands::compute <per_arm_cost_json> [gamma_low] [gamma_high]
# Emits per-arm JSON with cost bounds across Γ sweep ∈ {1.5, 2.0, 2.5, 3.0} (L0 §B11).
# Each arm gets band_at_1_5 / band_at_2_0 / band_at_2_5 / band_at_3_0, each with
# {cost_lower, cost_upper}. Top-level gamma_low/gamma_high/cost_lower/cost_upper
# track the outer Γ sweep envelope for additive-schema compatibility.
gamma_bands::compute() {
  local cost_json="$1" gl="${2:-1.5}" gh="${3:-3.0}"
  printf '%s\n' "$cost_json" | jq --argjson gl "$gl" --argjson gh "$gh" '
    to_entries | map({
      key: .key,
      value: {
        cost: .value,
        gamma_low: $gl,
        gamma_high: $gh,
        cost_lower: (.value / $gh),
        cost_upper: (.value * $gh),
        band_at_1_5: {cost_lower: (.value / 1.5), cost_upper: (.value * 1.5)},
        band_at_2_0: {cost_lower: (.value / 2.0), cost_upper: (.value * 2.0)},
        band_at_2_5: {cost_lower: (.value / 2.5), cost_upper: (.value * 2.5)},
        band_at_3_0: {cost_lower: (.value / 3.0), cost_upper: (.value * 3.0)}
      }
    }) | from_entries'
}

# gamma_bands::caveat - emits verbatim B11 marginal-sensitivity-model caveat.
# Delegates to aggregator_v2::cc12_caveat (source lib/aggregator-v2.sh first).
gamma_bands::caveat() {
  if declare -f aggregator_v2::cc12_caveat >/dev/null 2>&1; then
    aggregator_v2::cc12_caveat
  else
    printf 'gamma_bands::caveat: aggregator_v2::cc12_caveat is not defined (source lib/aggregator-v2.sh first)\n' >&2
    return 1
  fi
}
