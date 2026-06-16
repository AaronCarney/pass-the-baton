#!/usr/bin/env bash
# lib/cost-model-compact.sh - /compact arm cost model.
# Pure: no I/O, no jq. Depends on lib/cost-models.sh (must be sourced first).
# DR-1 / B2 formulas. Microcompact excluded.
set -u

if ! declare -f cost_models::price >/dev/null 2>&1; then
  echo "lib/cost-model-compact.sh: source lib/cost-models.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# Constants per L0 B2
_CMC_SYS_TOKENS=20000        # CLI default per L0 §B2; override here if Anthropic changes default
_CMC_COMPACT_INSTRUCTION_IN=1100
_CMC_SUMMARY_RATIO=0.10
_CMC_SUMMARY_FLOOR=2000
_CMC_SUMMARY_CEILING=20000

# cost_model_compact::summary_tokens <P> - emits S = clamp(0.10·P, floor, ceiling).
cost_model_compact::summary_tokens() {
  local P="$1"
  if ! [[ "$P" =~ ^[0-9]+$ ]]; then
    echo "cost_model_compact: P must be non-negative integer (got: $P)" >&2
    return 1
  fi
  LC_ALL=C awk -v p="$P" -v r="$_CMC_SUMMARY_RATIO" \
    -v floor="$_CMC_SUMMARY_FLOOR" -v ceil="$_CMC_SUMMARY_CEILING" \
    'BEGIN{ s = int(p * r); if (s < floor) s = floor; if (s > ceil) s = ceil; print s }'
}

# cost_model_compact::event_cost <model> <P> warm|cold - USD per single /compact event.
cost_model_compact::event_cost() {
  local model="$1" P="$2" cache_state="$3"
  if ! [[ "$P" =~ ^[0-9]+$ ]]; then
    echo "cost_model_compact: P must be non-negative integer (got: $P)" >&2
    return 1
  fi
  case "$cache_state" in warm|cold) ;; *) echo "cost_model_compact: cache_state must be warm|cold (got: $cache_state)" >&2; return 1 ;; esac
  local S; S="$(cost_model_compact::summary_tokens "$P")"
  local r_cr r_in r_out r_cw_5m
  r_cr="$(cost_models::price "$model" cache_read)" || return 2
  r_in="$(cost_models::price "$model" base_in)" || return 2
  r_out="$(cost_models::price "$model" base_out)" || return 2
  r_cw_5m="$(cost_models::price "$model" cache_write_5m)" || return 2
  local SysP=$(( _CMC_SYS_TOKENS + P ))
  # Warm: (Sys+P)·r_cr + 1100·r_in + S·r_out + S·r_cw_5m
  # Cold: (Sys+P)·r_in + 1100·r_in + S·r_out + S·r_cw_5m
  local syspart_rate
  if [[ "$cache_state" == "warm" ]]; then syspart_rate="$r_cr"; else syspart_rate="$r_in"; fi
  LC_ALL=C awk -v sysP="$SysP" -v sR="$syspart_rate" \
    -v instr="$_CMC_COMPACT_INSTRUCTION_IN" -v rin="$r_in" \
    -v S="$S" -v rout="$r_out" -v rcw="$r_cw_5m" \
    'BEGIN{ usd = (sysP*sR + instr*rin + S*rout + S*rcw) / 1000000.0; printf "%.6f\n", usd }'
}
