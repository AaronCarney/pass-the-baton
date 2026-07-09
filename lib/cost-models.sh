#!/bin/bash
# lib/cost-models.sh - single source of truth for per-model pricing primitives.
# Pure bash; sourced; no I/O; no network.

# Freshness anchor - T6 doctor reads this to warn when stale.
PRICING_VERIFIED_DATE="2026-06-21"

# Geo + fast multipliers (off by default - applied by cost_models::cost_of_turn).
INFERENCE_GEO_US_MULTIPLIER=1.10
FAST_MODE_MULTIPLIER=6.00

# ---------------------------------------------------------------------------
# PRICE table - USD per million tokens (MTok).
# Format: PRICE[<model>:<primitive>]=<value>
# Primitives: base_in  base_out  cache_write_5m  cache_write_1h  cache_read
# ---------------------------------------------------------------------------
declare -A _CM_PRICE=(
  ["claude-opus-4-8:base_in"]=5.00
  ["claude-opus-4-8:base_out"]=25.00
  ["claude-opus-4-8:cache_write_5m"]=6.25
  ["claude-opus-4-8:cache_write_1h"]=10.00
  ["claude-opus-4-8:cache_read"]=0.50

  ["claude-opus-4-7:base_in"]=5.00
  ["claude-opus-4-7:base_out"]=25.00
  ["claude-opus-4-7:cache_write_5m"]=6.25
  ["claude-opus-4-7:cache_write_1h"]=10.00
  ["claude-opus-4-7:cache_read"]=0.50

  ["claude-opus-4-6:base_in"]=5.00
  ["claude-opus-4-6:base_out"]=25.00
  ["claude-opus-4-6:cache_write_5m"]=6.25
  ["claude-opus-4-6:cache_write_1h"]=10.00
  ["claude-opus-4-6:cache_read"]=0.50

  ["claude-sonnet-4-6:base_in"]=3.00
  ["claude-sonnet-4-6:base_out"]=15.00
  ["claude-sonnet-4-6:cache_write_5m"]=3.75
  ["claude-sonnet-4-6:cache_write_1h"]=6.00
  ["claude-sonnet-4-6:cache_read"]=0.30

  ["claude-sonnet-4-5:base_in"]=3.00
  ["claude-sonnet-4-5:base_out"]=15.00
  ["claude-sonnet-4-5:cache_write_5m"]=3.75
  ["claude-sonnet-4-5:cache_write_1h"]=6.00
  ["claude-sonnet-4-5:cache_read"]=0.30

  ["claude-haiku-4-5:base_in"]=1.00
  ["claude-haiku-4-5:base_out"]=5.00
  ["claude-haiku-4-5:cache_write_5m"]=1.25
  ["claude-haiku-4-5:cache_write_1h"]=2.00
  ["claude-haiku-4-5:cache_read"]=0.10

  ["claude-fable-5:base_in"]=10.00
  ["claude-fable-5:base_out"]=50.00
  ["claude-fable-5:cache_write_5m"]=12.50
  ["claude-fable-5:cache_write_1h"]=20.00
  ["claude-fable-5:cache_read"]=1.00
)

# min_cache_tokens per model
declare -A _CM_MIN_CACHE=(
  ["claude-opus-4-8"]=4096
  ["claude-opus-4-7"]=4096
  ["claude-opus-4-6"]=4096
  ["claude-sonnet-4-6"]=2048
  ["claude-sonnet-4-5"]=1024
  ["claude-haiku-4-5"]=4096
  ["claude-fable-5"]=2048
)

# Pinned dated IDs - bump manually on intentional release.
declare -A _CM_PINNED=(
  ["claude-opus-4-8"]="claude-opus-4-8-20260101"
  ["claude-opus-4-7"]="claude-opus-4-7-20260101"
  ["claude-opus-4-6"]="claude-opus-4-6-20260101"
  ["claude-sonnet-4-6"]="claude-sonnet-4-6-20260101"
  ["claude-sonnet-4-5"]="claude-sonnet-4-5-20260101"
  ["claude-haiku-4-5"]="claude-haiku-4-5-20260101"
  ["claude-fable-5"]="claude-fable-5-20260101"
  # Pinned IDs also map to themselves (no warning).
  ["claude-opus-4-8-20260101"]="claude-opus-4-8-20260101"
  ["claude-opus-4-7-20260101"]="claude-opus-4-7-20260101"
  ["claude-opus-4-6-20260101"]="claude-opus-4-6-20260101"
  ["claude-sonnet-4-6-20260101"]="claude-sonnet-4-6-20260101"
  ["claude-sonnet-4-5-20260101"]="claude-sonnet-4-5-20260101"
  ["claude-haiku-4-5-20260101"]="claude-haiku-4-5-20260101"
  ["claude-fable-5-20260101"]="claude-fable-5-20260101"
)

# Canonical model alias list (stable order)
_CM_MODELS=(
  claude-opus-4-8
  claude-opus-4-7
  claude-opus-4-6
  claude-sonnet-4-6
  claude-sonnet-4-5
  claude-haiku-4-5
  claude-fable-5
)

# Opus models that support --fast
_cm_is_fast_eligible() {
  local m="$1"
  [[ "$m" == "claude-opus-4-6" || "$m" == "claude-opus-4-7" || "$m" == "claude-opus-4-8" ]]
}

# ---------------------------------------------------------------------------
# cost_models::price <model> <primitive>
#   Prints USD/MTok float. Returns 2 on unknown model or primitive.
# ---------------------------------------------------------------------------
cost_models::price() {
  local model="$1" prim="$2"
  local key="${model}:${prim}"
  if [[ -z "${_CM_PRICE[$key]+set}" ]]; then
    return 2
  fi
  echo "${_CM_PRICE[$key]}"
}

# ---------------------------------------------------------------------------
# cost_models::min_cache_tokens <model>
#   Prints integer minimum cache tokens.
# ---------------------------------------------------------------------------
cost_models::min_cache_tokens() {
  local model="$1"
  if [[ -z "${_CM_MIN_CACHE[$model]+set}" ]]; then
    return 2
  fi
  echo "${_CM_MIN_CACHE[$model]}"
}

# ---------------------------------------------------------------------------
# cost_models::resolve_id <model_alias>
#   Prints pinned ID. Emits stderr warning when alias != pinned. Returns 0.
# ---------------------------------------------------------------------------
cost_models::resolve_id() {
  local alias="$1"
  if [[ -z "${_CM_PINNED[$alias]+set}" ]]; then
    echo "$alias"
    return 0
  fi
  local pinned="${_CM_PINNED[$alias]}"
  if [[ "$alias" != "$pinned" ]]; then
    echo "baton: alias '$alias' resolved to pinned id '$pinned'; pin in lib/cost-models.sh updated $PRICING_VERIFIED_DATE" >&2
  fi
  echo "$pinned"
}

# ---------------------------------------------------------------------------
# cost_models::list
#   Prints one model alias per line (stable order).
# ---------------------------------------------------------------------------
cost_models::list() {
  local m
  for m in "${_CM_MODELS[@]}"; do
    echo "$m"
  done
}

# ---------------------------------------------------------------------------
# cost_models::cost_of_turn <model> <cache_read> <cache_write_5m> <cache_write_1h>
#                            <fresh_input> <output> [--geo us] [--fast]
#   Prints USD float to 6 decimal places. Uses awk for math.
#   Exits 2 on unknown model. Exits 1 if --fast used on non-Opus-4.6/4.7.
# ---------------------------------------------------------------------------
cost_models::cost_of_turn() {
  local model="$1"
  local cache_read="$2"
  local cache_write_5m="$3"
  local cache_write_1h="$4"
  local fresh_input="$5"
  local output="$6"
  shift 6

  # Validate model
  if [[ -z "${_CM_PRICE[${model}:base_in]+set}" ]]; then
    return 2
  fi

  # Validate numeric args. awk silently coerces non-numeric strings to 0,
  # which would return a false $0.00 cost. Require non-negative integers.
  local _arg
  for _arg in "$cache_read" "$cache_write_5m" "$cache_write_1h" "$fresh_input" "$output"; do
    if ! [[ "$_arg" =~ ^[0-9]+$ ]]; then
      echo "baton: cost_of_turn: non-negative integer required, got '$_arg'" >&2
      return 2
    fi
  done

  local geo_mult=1
  local fast_mult=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --geo)
        shift
        case "$1" in
          us) geo_mult="$INFERENCE_GEO_US_MULTIPLIER" ;;
          *)
            echo "baton: --geo region '$1' is not recognised (supported: us)" >&2
            return 1
            ;;
        esac
        shift
        ;;
      --fast)
        if ! _cm_is_fast_eligible "$model"; then
          echo "baton: --fast is only available for claude-opus-4-6 and claude-opus-4-7" >&2
          return 1
        fi
        fast_mult="$FAST_MODE_MULTIPLIER"
        shift
        ;;
      *) shift ;;
    esac
  done

  local p_cr="${_CM_PRICE[${model}:cache_read]}"
  local p_cw5="${_CM_PRICE[${model}:cache_write_5m]}"
  local p_cw1="${_CM_PRICE[${model}:cache_write_1h]}"
  local p_fi="${_CM_PRICE[${model}:base_in]}"
  local p_out="${_CM_PRICE[${model}:base_out]}"

  LC_ALL=C awk -v cr="$cache_read" \
      -v cw5="$cache_write_5m" \
      -v cw1="$cache_write_1h" \
      -v fi="$fresh_input" \
      -v out="$output" \
      -v p_cr="$p_cr" \
      -v p_cw5="$p_cw5" \
      -v p_cw1="$p_cw1" \
      -v p_fi="$p_fi" \
      -v p_out="$p_out" \
      -v geo="$geo_mult" \
      -v fast="$fast_mult" \
      'BEGIN {
        cost = (cr*p_cr + cw5*p_cw5 + cw1*p_cw1 + fi*p_fi + out*p_out) / 1000000
        printf "%.6f\n", cost * geo * fast
      }'
}
