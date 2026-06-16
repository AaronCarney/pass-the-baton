#!/usr/bin/env bash
# lib/cost-compare-model.sh - Brief 4 §3/§4 economic model.
# Pure: no I/O, no jq. Depends only on lib/cost-models.sh (must be sourced first).
# Oracle is cost_models::cost_of_turn (first-principles), NOT Brief 4 §4's stated $.

# _ccmp_sum_floats <f1> <f2> -> f1+f2  (LC_ALL=C: E8 locale precedent)
_ccmp_add() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", a+b}'; }
_ccmp_lt()  { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<b+0)}'; }

# ccmp::derive_prefix - sum of first 4 fields of the first row of a TSV stream
# from transcript::turn_stream. Definition matches the inline prefix formula
# previously hard-coded in tools/cost-compare.sh (turn-1 non-output input:
# cache_read + cache_creation_5m + cache_creation_1h + fresh_input).
# Stream is read on stdin. Empty stream emits 0.
ccmp::derive_prefix() {
  awk -F'\t' 'NR==1{print $1+0 + $2+0 + $3+0 + $4+0; exit} END{if (NR==0) print 0}'
}

# ccmp::derive_summary_tokens_default - scan recorded progress files (active +
# archived) and emit "<tokens>|<source note>" on stdout. Uses a delimited line
# because bash's $()-capture runs in a subshell and would swallow a global
# side-effect write. Honors BATON_PROGRESS_DIR + BATON_ARCHIVE_DIR
# (see docs/context-baton.md "Configuration (env vars)").
# Depends on tokens::estimate_file from lib/tokens.sh - caller must source it.
ccmp::derive_summary_tokens_default() {
  # 1. State-file probe (E19 T7).
  local _stm_lib
  _stm_lib="${BASH_SOURCE[0]%/*}/summary-tokens-mean.sh"
  if [ -f "$_stm_lib" ]; then
    # shellcheck disable=SC1090
    source "$_stm_lib"
    local stm_mean stm_n stm_path
    stm_mean="$(_stm::read 2>/dev/null || true)"
    stm_path="$(_stm::path 2>/dev/null || true)"
    # Mean is a running float (e.g. 2595.52); downstream consumers (summary_gen_cost
    # guard, JSON, integer arithmetic) require an integer token count - round it.
    if [ -n "$stm_mean" ]; then
      stm_mean=$(LC_ALL=C awk -v m="$stm_mean" 'BEGIN{printf "%d", m + 0.5}')
    fi
    if [ -n "$stm_mean" ] && [ "$stm_mean" != '0' ]; then
      stm_n=$(jq -r '.n // 0' "$stm_path" 2>/dev/null || echo 0)
      printf '%s|state-file (running-mean of %s summary turns at %s)\n' \
        "$stm_mean" "$stm_n" "$stm_path"
      return 0
    fi
  fi
  # 2. Progress-file scan (verbatim from prior behavior).
  local prog_dir="${BATON_PROGRESS_DIR:-${BATON_DIR:-$PWD/.baton}/progress}"
  local archive_dir="${BATON_ARCHIVE_DIR:-$HOME/.local/share/baton}"
  local total=0 count=0 f tok
  if [ -d "$prog_dir" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      tok=$(tokens::estimate_file "$f" prose 2>/dev/null) || continue
      total=$(( total + tok )); count=$(( count + 1 ))
    done < <(find "$prog_dir" -maxdepth 1 -name 'progress-*.md' -type f 2>/dev/null)
  fi
  if [ -d "$archive_dir/checkpoint-state" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      tok=$(tokens::estimate_file "$f" prose 2>/dev/null) || continue
      total=$(( total + tok )); count=$(( count + 1 ))
    done < <(find "$archive_dir/checkpoint-state" -name 'progress-*.md' -type f 2>/dev/null)
  fi
  # 3. Final fallback.
  if [ "$count" -eq 0 ]; then
    printf '%s|%s\n' "2500" "default (no recorded progress files found)"
  else
    printf '%s|%s\n' "$(( total / count ))" "measured average over $count recorded progress files"
  fi
}

# ccmp::derive_sg_in_rate - cross-model summarizer-input rate (USD per
# input token). Returns "0" when summary_model matches session_model OR
# when summary_tokens<=0; otherwise emits "%.12f" of base_in/1_000_000 for
# the summary model. Lifted from tools/cost-compare.sh:128-132 so the
# corpus aggregator and per-transcript tool stay byte-identical at this
# math boundary. The case guard validates summary_tokens defensively so
# callers do not need to pre-validate.
ccmp::derive_sg_in_rate() {
  local summary_model="$1" session_model="$2" summary_tokens="$3"
  case "$summary_tokens" in
    ''|*[!0-9]*) printf '%s' "0"; return 0;;
  esac
  if [ "$summary_model" = "$session_model" ] || [ "$summary_tokens" -eq 0 ]; then
    printf '%s' "0"; return 0
  fi
  local base_in
  base_in=$(cost_models::price "$summary_model" base_in)
  LC_ALL=C awk -v p="$base_in" 'BEGIN{printf "%.12f", p/1000000}'
}

# ccmp::summary_gen_cost <model> <summary_tokens> -> USD to generate ONE resume
# summary (prior-session OUTPUT). The incremental input to summarize is already
# sunk in the pre-checkpoint conversation; the marginal new spend is the
# generated output. Reuses cost_of_turn (geo/fast-aware), no new constants.
ccmp::summary_gen_cost() {
  local model="$1" s="${2:-0}"
  # Input contract: non-negative integer. Library callers (and the CLI under
  # set -u) need an explicit guard; mirrors the SUMMARY_TOKENS case-glob in
  # tools/cost-compare.sh. Non-integers and negatives collapse to 0 (the
  # same semantic as S=0 / --summary-tokens 0 - pre-2026-05 behavior).
  case "$s" in
    ''|*[!0-9]*) printf '0.000000'; return 0;;
  esac
  if [ "$s" -le 0 ]; then printf '0.000000'; return 0; fi
  cost_models::cost_of_turn "$model" 0 0 0 0 "$s"
}

# ccmp::uncached_total <model> <prefix> <stream>
# Context grows every turn; all input billed at base_in.
ccmp::uncached_total() {
  local model="$1" prefix="$2" stream="$3" total="0.000000" hist=0 cr cw5 cw1 fi out inp c
  while IFS=$'\t' read -r cr cw5 cw1 fi out; do
    [ -z "${out:-}" ] && continue
    inp=$(( prefix + hist + fi ))
    c=$(cost_models::cost_of_turn "$model" 0 0 0 "$inp" "$out")
    total=$(_ccmp_add "$total" "$c")
    hist=$(( hist + fi + out ))
  done <<< "$stream"
  printf '%s' "$total"
}

# ccmp::cached_total <model> <prefix> <stream>
# Turn 1: one 5m cache write over prefix. Turns 2..N: prefix+history read at cache_read.
ccmp::cached_total() {
  local model="$1" prefix="$2" stream="$3" sg="${4:-0.000000}" total="0.000000" hist=0 n=0 cr cw5 cw1 fi out c
  while IFS=$'\t' read -r cr cw5 cw1 fi out; do
    [ -z "${out:-}" ] && continue
    n=$(( n + 1 ))
    if [ "$n" -eq 1 ]; then
      c=$(cost_models::cost_of_turn "$model" 0 "$prefix" 0 "$fi" "$out")
      total=$(_ccmp_add "$total" "$sg")
    else
      c=$(cost_models::cost_of_turn "$model" $(( prefix + hist )) 0 0 "$fi" "$out")
    fi
    total=$(_ccmp_add "$total" "$c")
    hist=$(( hist + fi + out ))
  done <<< "$stream"
  printf '%s' "$total"
}

# ccmp::breakeven_turn <model> <prefix> <stream> -> first k where cached_cum<uncached_cum, else 0
ccmp::breakeven_turn() {
  local model="$1" prefix="$2" stream="$3" sg="${4:-0.000000}"
  local rows; rows=$(printf '%s\n' "$stream" | grep -c .)
  local i sub
  for (( i=1; i<=rows; i++ )); do
    sub=$(printf '%s\n' "$stream" | sed -n "1,${i}p")
    if _ccmp_lt "$(ccmp::cached_total "$model" "$prefix" "$sub" "$sg")" \
                "$(ccmp::uncached_total "$model" "$prefix" "$sub")"; then
      printf '%s' "$i"; return 0
    fi
  done
  printf '0'
}

# ccmp::threshold_sweep <model> <prefix> <stream> "<T1 T2 ... never>" [<sg>] [<sg_in_rate>]
# Emits "<T>\t<total_usd>" per threshold. The session STARTS uncached
# (context grows) and stays uncached until context-fill (cumulative_input/1e6)
# first reaches T/100; that turn's /clear+resume makes the NEXT turn the first
# cached turn (bundled prefix cache-write, like cached_total turn 1), then
# turns read prefix+history at cache_read. A fresh crossing of T/100 re-clears.
# A high T runs uncached longer; a low T checkpoints sooner. 'never' = pure
# uncached. A session whose fill never reaches T/100 correctly equals uncached.
#
# sg_in_rate (USD/input-token) models the summarizer's INPUT cost at each /clear
# when the summary writer is a DIFFERENT model from the session model. The
# default sg_in_rate=0 reproduces the same-model assumption ("input is sunk in
# the existing session cache"). A non-zero rate charges (fill × sg_in_rate) at
# every checkpoint firing - i.e., the cross-model summarizer reads the
# pre-/clear context as fresh input billed at its own base_in.
ccmp::threshold_sweep() {
  local model="$1" prefix="$2" stream="$3" thresholds="$4" sg="${5:-0.000000}" sg_in_rate="${6:-0}" T total hist cr cw5 cw1 fi out inp c fill phase sg_in
  for T in $thresholds; do
    if [ "$T" = "never" ]; then
      printf '%s\t%s\n' "never" "$(ccmp::uncached_total "$model" "$prefix" "$stream")"
      continue
    fi
    total="0.000000"; hist=0; phase=uncached
    while IFS=$'\t' read -r cr cw5 cw1 fi out; do
      [ -z "${out:-}" ] && continue
      case "$phase" in
        uncached)
          inp=$(( prefix + hist + fi ))
          c=$(cost_models::cost_of_turn "$model" 0 0 0 "$inp" "$out") ;;
        first_cached)
          c=$(cost_models::cost_of_turn "$model" 0 "$prefix" 0 "$fi" "$out")
          phase=cached ;;
        cached)
          c=$(cost_models::cost_of_turn "$model" $(( prefix + hist )) 0 0 "$fi" "$out") ;;
      esac
      total=$(_ccmp_add "$total" "$c")
      hist=$(( hist + fi + out ))
      fill=$(( prefix + hist ))
      # checkpoint when fill% >= T  ->  /clear+resume: reset history, next turn
      # is the first cached turn (pays the bundled prefix cache-write). NOTE:
      # for a pathologically low T (< prefix's own fill%), the post-reset
      # fill==prefix already exceeds T, so the next turn re-enters first_cached
      # every iteration - checkpoint thrash. This is faithful (a too-low T is
      # genuinely wasteful), not a bug; realistic T (20/28/40) >> ~5% prefix.
      if LC_ALL=C awk -v f="$fill" -v t="$T" 'BEGIN{exit !((f/1000000.0*100.0)>=t)}'; then
        # /clear fires -> a resume summary was generated by the prior session.
        # Charge the per-/clear USD SCALAR directly (caller already priced it
        # against the summary-writer's model, not necessarily $model). Thrash
        # multiplies; high T amortizes; sg=0 leaves totals unchanged.
        total=$(_ccmp_add "$total" "$sg")
        # Cross-model summarizer also pays INPUT for reading pre-/clear context
        # (fill tokens) at its own base_in rate. Same-model summarizers reuse
        # the existing session cache and pass rate=0 from the CLI.
        if _ccmp_lt 0 "$sg_in_rate"; then
          sg_in=$(LC_ALL=C awk -v r="$sg_in_rate" -v f="$fill" 'BEGIN{printf "%.6f", r*f}')
          total=$(_ccmp_add "$total" "$sg_in")
        fi
        hist=0; phase=first_cached
      fi
    done <<< "$stream"
    printf '%s\t%s\n' "$T" "$total"
  done
}

# ccmp::payoff_guards <model> <prefix> <stream> -> space-list of guard tokens (Brief 4 §4)
ccmp::payoff_guards() {
  local model="$1" prefix="$2" stream="$3" rows min g=""
  rows=$(printf '%s\n' "$stream" | grep -c .)
  [ "$rows" -lt 2 ] && g="$g single_turn"
  min=$(cost_models::min_cache_tokens "$model")
  [ "$prefix" -lt "$min" ] && g="$g prefix_below_min"
  printf '%s' "${g# }"
}
