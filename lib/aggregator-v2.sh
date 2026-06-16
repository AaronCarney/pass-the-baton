#!/usr/bin/env bash
# lib/aggregator-v2.sh - pure helpers for aggregator schema v2 (CC6 / D3).
# Per-arm-per-subset JSON block assembly + B11 caveat + subset-size warning.
# Pure functions - no I/O beyond jq invocation; no global state.
set -u

_AGV2_ARMS_RE='^(compact|auto-memory|clear-only|none)$'
_AGV2_SUBSETS_RE='^(clean|fired)$'

# aggregator_v2::per_arm_per_subset_block <arm> <subset> <usd_total> <session_count>
#   Emits a compact JSON object (no trailing newline from jq -c).
aggregator_v2::per_arm_per_subset_block() {
  local arm="$1" subset="$2" usd="$3" n="$4"
  if ! [[ "$arm" =~ $_AGV2_ARMS_RE ]]; then
    echo "aggregator_v2: arm must be compact|auto-memory|clear-only|none (got: $arm)" >&2
    return 1
  fi
  if ! [[ "$subset" =~ $_AGV2_SUBSETS_RE ]]; then
    echo "aggregator_v2: subset must be clean|fired (got: $subset)" >&2
    return 1
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "aggregator_v2: session_count must be non-negative integer (got: $n)" >&2
    return 1
  fi
  jq -cn --arg arm "$arm" --arg subset "$subset" --arg usd "$usd" --argjson n "$n" \
    '{arm:$arm, subset:$subset, usd_total:$usd, session_count:$n}'
}

# aggregator_v2::cc12_caveat
#   Emits the verbatim B11 methodological caveat as a JSON-quoted string
#   (no surrounding object). Source: L0 §B11 - the QUOTED caveat ends at
#   "...a single point estimate is not." The `Cites Yehudai... Mohammadi...`
#   attribution is L0 prose AROUND the caveat, not part of it, and is rendered
#   as a separate line in the doc (see the replay-harness design (maintained internally)), not inlined.
#   L0 uses Γ; ASCII "Gamma" substituted for emission portability (avoids
#   bash/jq locale-encoding surprises with non-ASCII bytes in older locales).
aggregator_v2::cc12_caveat() {
  jq -cn --arg s 'This comparison adapts marginal-sensitivity-model methodology from observational epidemiology to the LLM-agent setting. No peer-reviewed paper has validated end-to-end DM-OPE-with-MSM-Gamma-bounds for cost evaluation under arm-induced trajectory drift in LLM agents specifically. The bounded estimator is the methodologically defensible answer; a single point estimate is not.' '$s'
}

# aggregator_v2::subset_size_warning <clean_share>
#   Emits JSON null if clean_share >= 0.30, else a JSON-quoted warning string
#   citing the 30% L0 sample-size floor and B11. clean_share must be 0.0..1.0.
aggregator_v2::subset_size_warning() {
  local share="$1"
  if ! [[ "$share" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "aggregator_v2: clean_share must be a float (got: $share)" >&2
    return 1
  fi
  local oob; oob=$(LC_ALL=C awk -v s="$share" 'BEGIN{ print (s < 0 || s > 1) ? 1 : 0 }')
  if [ "$oob" -eq 1 ]; then
    echo "aggregator_v2: clean_share out of [0,1] (got: $share)" >&2
    return 1
  fi
  local below; below=$(LC_ALL=C awk -v s="$share" 'BEGIN{ print (s < 0.30) ? 1 : 0 }')
  if [ "$below" -eq 0 ]; then
    printf '%s' 'null'
    return 0
  fi
  local pct; pct=$(LC_ALL=C awk -v s="$share" 'BEGIN{ printf "%.1f", s*100 }')
  jq -cn --arg s "Clean subset is $pct% of total sessions; below 30% L0 sample-size floor - headline is bound-only per B11." '$s'
}
