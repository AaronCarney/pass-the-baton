#!/usr/bin/env bash
# lib/recommend-aggregate.sh - top-level aggregator for the recommend pipeline.
# Calls T2-T6 functions + recommend_window::from, assembles unified evidence JSON.
# JSON shape: {winners, per_method:{cost,time,outcome}, paired_deltas,
#              threshold_sweep, caveats, window, session_count}
set -uo pipefail

_RAGG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source all extractor libs
source "$_RAGG_REPO/lib/release-dates.sh"
source "$_RAGG_REPO/lib/recommend-cost-extract.sh"
source "$_RAGG_REPO/lib/recommend-time-extract.sh"
source "$_RAGG_REPO/lib/recommend-outcome-extract.sh"
source "$_RAGG_REPO/lib/recommend-paired-deltas.sh"
source "$_RAGG_REPO/lib/recommend-threshold-sweep.sh"
source "$_RAGG_REPO/lib/eventlog.sh"

# recommend_window::from EVENTS_FILE [SINCE_OVERRIDE]
# Returns YYYY-MM-DD: min .ts from events, or --since override, or 180-day fallback.
recommend_window::from() {
  local events="$1"
  local since="${2:-}"
  if [[ -n "$since" ]]; then
    echo "$since"
    return 0
  fi
  local today_iso="${CC_NOW:-$(date -u +%Y-%m-%d)}"
  local min_ts
  if [[ -f "$events" ]]; then
    min_ts=$(eventlog::stream "$events" | jq -rs '[.[] | .ts] | min // empty' 2>/dev/null || true)
  fi
  if [[ -n "${min_ts:-}" ]]; then
    echo "${min_ts%T*}"
  else
    date -u -d "$today_iso - 180 days" +%Y-%m-%d
  fi
}

# recommend_window::session_count EVENTS_FILE FROM TO [STRICT_RECENT]
# Counts distinct project_boundary 'start' session_ids in window [FROM, TO].
# With --strict-recent true: drops sessions whose cost_rollup events have
#   .ts < release_dates::for_model(.data.model).
recommend_window::session_count() {
  local events="$1"
  local from="$2"
  local to="$3"
  local strict="${4:-false}"

  if [[ ! -f "$events" ]]; then
    echo 0
    return 0
  fi

  if [[ "$strict" == "true" ]]; then
    # Build dropped session set: cost_rollup events where ts < release_date of model
    local dropped_json="[]"
    while IFS= read -r line; do
      local model ts
      model=$(printf '%s' "$line" | jq -r '.data.model // empty' 2>/dev/null)
      ts=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
      local sid
      sid=$(printf '%s' "$line" | jq -r '.data.session_id // empty' 2>/dev/null)
      [[ -z "$model" ]] || [[ -z "$ts" ]] || [[ -z "$sid" ]] && continue
      local rel_date
      rel_date=$(release_dates::for_model "$model")
      [[ -z "$rel_date" ]] && continue
      # Drop if ts < release_date (session ran before model was released)
      local ts_date="${ts%T*}"
      if [[ "$ts_date" < "$rel_date" ]]; then
        dropped_json=$(printf '%s' "$dropped_json" | jq --arg s "$sid" '. + [$s] | unique')
      fi
    done < <(eventlog::stream "$events" | jq -c 'select(.event=="cost_rollup")' 2>/dev/null || true)

    # Count start events not in dropped set. Bind sid to $s before index() (. is rebound by pipe).
    eventlog::stream "$events" | jq -rs --argjson dropped "$dropped_json" \
      '[.[] | select(.event=="project_boundary" and .data.kind=="start")
         | .data.session_id
         | select(. != null)
         | . as $s | select(($dropped | index($s)) == null)
       ] | unique | length' 2>/dev/null || echo 0
  else
    # Raw count of distinct project_boundary 'start' session_ids
    eventlog::stream "$events" | jq -rs '[.[] | select(.event=="project_boundary" and .data.kind=="start")
              | (.data.session_id // .data.terminal_id)
              | select(. != null)
            ] | unique | length' 2>/dev/null || echo 0
  fi
}

# recommend::aggregate - main entry point
# Accepts: --cost PATH --time PATH --outcome PATH --events PATH
#          --arms-dir PATH [--since DATE] [--to DATE] [--strict-recent BOOL]
recommend::aggregate() {
  local cost_path="" time_path="" outcome_path="" events_path="" arms_dir=""
  local since_date="" to_date="" strict_recent="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cost)       cost_path="$2";    shift 2 ;;
      --time)       time_path="$2";    shift 2 ;;
      --outcome)    outcome_path="$2"; shift 2 ;;
      --events)     events_path="$2";  shift 2 ;;
      --arms-dir)   arms_dir="$2";     shift 2 ;;
      --since)      since_date="$2";   shift 2 ;;
      --to)         to_date="$2";      shift 2 ;;
      --strict-recent) strict_recent="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local today_iso="${CC_NOW:-$(date -u +%Y-%m-%d)}"
  local to_iso="${to_date:-$today_iso}"

  # ── Window ──────────────────────────────────────────────────────────────────
  local win_from
  win_from=$(recommend_window::from "${events_path:-}" "$since_date")
  local win_to="$to_iso"

  # ── Session count ───────────────────────────────────────────────────────────
  local sess_count=0
  if [[ -n "$events_path" ]] && [[ -f "$events_path" ]]; then
    sess_count=$(recommend_window::session_count "$events_path" "$win_from" "$win_to" "$strict_recent")
  fi

  # ── Cost winner + per_method + threshold_sweep ───────────────────────────────
  local degenerate=false
  if [[ "${REPLAY_HARNESS_NONZERO_ARMS:-}" == "0" ]]; then
    degenerate=true
  fi

  local cost_winner="null"
  local pm_cost="{}"
  local threshold_sweep='{"argmax":null,"candidates":[],"savings_vs_22_at_argmax":null,"ci":null}'

  if [[ "$degenerate" == "false" ]] && [[ -n "$cost_path" ]] && [[ -f "$cost_path" ]]; then
    cost_winner=$(recommend_cost::winner "$cost_path")
    pm_cost=$(recommend_cost::per_method "$cost_path")
    threshold_sweep=$(recommend_threshold::sweep "$cost_path" 2>/dev/null || printf '%s' "$threshold_sweep")
  fi

  # ── Time winner + per_method ─────────────────────────────────────────────────
  local time_winner="null"
  local pm_time="{}"
  if [[ -n "$time_path" ]] && [[ -f "$time_path" ]]; then
    time_winner=$(recommend_time::winner "$time_path")
    pm_time=$(recommend_time::per_method "$time_path")
  fi

  # ── Outcome winner + per_method + post_e16_days ───────────────────────────────
  local outcome_winner="null"
  local pm_outcome="{}"
  local post_e16_days="null"

  if [[ -n "$events_path" ]] && [[ -f "$events_path" ]]; then
    local raw_days
    raw_days=$(recommend_outcome::post_e16_days "$events_path")
    if [[ -n "$raw_days" ]]; then
      post_e16_days="$raw_days"
    fi
  fi

  local outcome_insufficient=false
  if [[ -n "$outcome_path" ]] && [[ -f "$outcome_path" ]]; then
    pm_outcome=$(recommend_outcome::per_method "$outcome_path")
    if [[ "$post_e16_days" != "null" ]]; then
      local insuff
      insuff=$(recommend_outcome::is_insufficient "$post_e16_days")
      if [[ "$insuff" == "true" ]]; then
        outcome_insufficient=true
        outcome_winner="null"
      else
        outcome_winner=$(recommend_outcome::winner "$outcome_path")
      fi
    else
      outcome_winner=$(recommend_outcome::winner "$outcome_path")
    fi
  fi

  # ── Paired deltas ────────────────────────────────────────────────────────────
  local paired_deltas="{}"
  if [[ "$degenerate" == "false" ]] && [[ -n "$arms_dir" ]] && [[ -d "$arms_dir" ]]; then
    paired_deltas=$(recommend_paired::all_pairs "$arms_dir" 2>/dev/null || echo "{}")
  fi

  # ── Caveats ──────────────────────────────────────────────────────────────────
  # data_age_crossing: any known release dates fall within (win_from, win_to]
  local crossings_list="[]"
  local data_age_crossing=false
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local m d
    m="${line%% *}"
    d="${line##* }"
    crossings_list=$(printf '%s' "$crossings_list" | jq --arg m "$m" --arg d "$d" '. + [{model:$m,date:$d}]')
    data_age_crossing=true
  done < <(release_dates::crossings "$win_from" "$win_to" 2>/dev/null || true)

  # no_significant_difference: any paired-delta CI straddles zero
  local no_sig_diff=false
  if [[ "$paired_deltas" != "{}" ]]; then
    local straddles
    straddles=$(printf '%s' "$paired_deltas" | jq '
      [to_entries[] | .value.clean.ci |
        select(. != null and .ci_lower != null and .ci_upper != null) |
        select(.ci_lower < 0 and .ci_upper > 0)
      ] | length > 0' 2>/dev/null || echo "false")
    [[ "$straddles" == "true" ]] && no_sig_diff=true
  fi

  # ── Assemble JSON ────────────────────────────────────────────────────────────
  # Normalize string "null" from jq -r calls to actual JSON null
  local cost_winner_json time_winner_json outcome_winner_json
  [[ "$cost_winner" == "null" ]]    && cost_winner_json="null"    || cost_winner_json="\"$cost_winner\""
  [[ "$time_winner" == "null" ]]    && time_winner_json="null"    || time_winner_json="\"$time_winner\""
  [[ "$outcome_winner" == "null" ]] && outcome_winner_json="null" || outcome_winner_json="\"$outcome_winner\""

  local post_e16_json
  [[ "$post_e16_days" == "null" ]] && post_e16_json="null" || post_e16_json="$post_e16_days"

  jq -n \
    --argjson cost_winner "$cost_winner_json" \
    --argjson time_winner "$time_winner_json" \
    --argjson outcome_winner "$outcome_winner_json" \
    --argjson pm_cost "$pm_cost" \
    --argjson pm_time "$pm_time" \
    --argjson pm_outcome "$pm_outcome" \
    --argjson paired_deltas "$paired_deltas" \
    --argjson threshold_sweep "$threshold_sweep" \
    --argjson session_count "$sess_count" \
    --arg win_from "$win_from" \
    --arg win_to "$win_to" \
    --argjson post_e16_days "$post_e16_json" \
    --argjson data_age_crossing "$data_age_crossing" \
    --argjson crossings "$crossings_list" \
    --argjson outcome_insufficient "$outcome_insufficient" \
    --argjson no_sig_diff "$no_sig_diff" \
    --argjson cost_producer_degenerate "$degenerate" \
    '{
      winners: {cost: $cost_winner, time: $time_winner, outcome: $outcome_winner},
      per_method: {cost: $pm_cost, time: $pm_time, outcome: $pm_outcome},
      paired_deltas: $paired_deltas,
      threshold_sweep: $threshold_sweep,
      caveats: {
        data_age_crossing: $data_age_crossing,
        crossings: $crossings,
        outcome_data_insufficient: $outcome_insufficient,
        no_significant_difference: $no_sig_diff,
        cost_producer_degenerate: $cost_producer_degenerate
      },
      window: {from: $win_from, to: $win_to, post_e16_days: $post_e16_days},
      session_count: $session_count
    }'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  recommend::aggregate "$@"
fi
