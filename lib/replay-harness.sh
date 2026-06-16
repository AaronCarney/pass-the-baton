#!/usr/bin/env bash
# lib/replay-harness.sh - compose E13a cost-model arms over a transcript.
# Pure-bash; jq only at the transcript-read boundary via transcript:: helpers.
# CC1 honored - arithmetic delegated to cost-model arm libs.
set -u

for _fn in cost_model_compact::event_cost cost_model_automemory::event_cost \
           cost_model_clear_only::event_cost cost_model_none::trajectory_cost \
           cost_model_none::turn_cost transcript::turn_stream \
           transcript::ctx_out_stream; do
  if ! declare -f "$_fn" >/dev/null 2>&1; then
    echo "lib/replay-harness.sh: required function not in scope: $_fn" >&2
    echo "  source order: lib/cost-models.sh, lib/cost-model-*.sh, lib/transcript.sh, then this file." >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _fn

_rh_assert_inputs() {
  local model="$1" tpath="$2"
  if [ -z "$model" ]; then echo "replay_harness: model required" >&2; return 1; fi
  if [ -z "$tpath" ]; then echo "replay_harness: transcript path required" >&2; return 1; fi
  if [ ! -f "$tpath" ]; then echo "replay_harness: transcript not found: $tpath" >&2; return 1; fi
  return 0
}

# replay_harness::none_total <model> <transcript_path>
#   Sums turn costs across the trajectory at full base_in (monotonic baseline).
#   Uses transcript::ctx_out_stream (2-col projection) NOT turn_stream (5-col) -
#   cost_model_none::trajectory_cost expects <ctx>\t<out>.
replay_harness::none_total() {
  local model="$1" tpath="$2"
  _rh_assert_inputs "$model" "$tpath" || return 1
  transcript::ctx_out_stream "$tpath" 2>/dev/null | cost_model_none::trajectory_cost "$model"
}

# replay_harness::clear_only_total <model> <transcript_path>
#   Per-turn cost as cost_model_none::turn_cost; at each /clear boundary, adds
#   cost_model_clear_only::event_cost (=0). The reset-to-cold semantics are
#   modelled by the fact that no separate "warm" credit accrues in any arm -
#   none::turn_cost already prices every turn at full base_in.
replay_harness::clear_only_total() {
  local model="$1" tpath="$2"
  _rh_assert_inputs "$model" "$tpath" || return 1
  local stream_total clear_n ev_cost
  stream_total="$(transcript::ctx_out_stream "$tpath" 2>/dev/null | cost_model_none::trajectory_cost "$model")" || return $?
  clear_n=$(transcript::clear_events "$tpath" | wc -l | awk '{print $1}')
  ev_cost="$(cost_model_clear_only::event_cost)"
  LC_ALL=C awk -v st="$stream_total" -v n="$clear_n" -v ev="$ev_cost" \
    'BEGIN{ printf "%.6f\n", st + (n * ev) }'
}

# replay_harness::automemory_total <model> <transcript_path> <automemory_tokens>
#   Per-turn none::turn_cost + per-turn auto-memory surcharge (first on turn 0,
#   within-ttl thereafter; post-compact turns use cost_model_automemory::event_cost
#   post-compact mode (=0) per CC1 - we don't invent reset arithmetic). Uses
#   transcript::ctx_out_stream for the 2-col stream into trajectory_cost.
#   Surcharge formula: first + (n - 1 - nc) * within
replay_harness::automemory_total() {
  local model="$1" tpath="$2" tokens="$3"
  _rh_assert_inputs "$model" "$tpath" || return 1
  if ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
    echo "replay_harness: automemory_tokens must be non-negative integer (got: $tokens)" >&2
    return 1
  fi

  local first_cost within_cost
  first_cost="$(cost_model_automemory::event_cost "$model" "$tokens" first)" || return $?
  within_cost="$(cost_model_automemory::event_cost "$model" "$tokens" within-ttl)" || return $?

  local n_turns
  n_turns=$(transcript::turn_stream "$tpath" 2>/dev/null | wc -l | awk '{print $1}')
  [ "$n_turns" -eq 0 ] && { printf '%.6f\n' 0; return 0; }

  local stream_total
  stream_total="$(transcript::ctx_out_stream "$tpath" 2>/dev/null | cost_model_none::trajectory_cost "$model")" || return $?

  local n_compact
  n_compact=$(transcript::compact_events "$tpath" | wc -l | awk '{print $1}')

  LC_ALL=C awk -v st="$stream_total" -v n="$n_turns" -v nc="$n_compact" \
    -v fc="$first_cost" -v wc_val="$within_cost" \
    'BEGIN{
      within_n = ((n - 1 - nc) < 0 ? 0 : (n - 1 - nc))
      surcharge = fc + within_n * wc_val
      printf "%.6f\n", st + surcharge
    }'
}

# replay_harness::compact_total <model> <transcript_path>
#   Per-turn none::turn_cost + per-/compact-boundary cost_model_compact::event_cost.
#   `P` for each boundary is read from the transcript's `pre_compact_tokens` field
#   on the compact_boundary line; if absent, falls back to summing input_tokens
#   (column 4 of turn_stream) for all turns BEFORE the boundary's turn_index.
#   Cache state: warm unconditionally (v1 simplifying assumption; E13c may add
#   timestamp-based warm/cold inference).
replay_harness::compact_total() {
  local model="$1" tpath="$2"
  _rh_assert_inputs "$model" "$tpath" || return 1

  local stream_total
  stream_total="$(transcript::ctx_out_stream "$tpath" 2>/dev/null | cost_model_none::trajectory_cost "$model")" || return $?

  # Materialize input_tokens (col 4 of turn_stream) per turn for the fallback path.
  local turn_inputs_file
  turn_inputs_file="$(mktemp)"
  transcript::turn_stream "$tpath" 2>/dev/null | awk -F'\t' '{ print $4 }' > "$turn_inputs_file"

  local boundary_total=0 P bidx fallback_P boundary_cost
  while IFS=$'\t' read -r P bidx; do
    [ -z "$P" ] && continue
    if [ "$P" = '-1' ]; then
      fallback_P=$(LC_ALL=C awk -v lim="$bidx" 'NR <= lim { s += $1 } END { print (s+0) }' "$turn_inputs_file")
      P="$fallback_P"
    fi
    boundary_cost="$(cost_model_compact::event_cost "$model" "$P" warm)" || { rm -f "$turn_inputs_file"; return $?; }
    boundary_total=$(LC_ALL=C awk -v a="$boundary_total" -v b="$boundary_cost" 'BEGIN{ printf "%.6f", a + b }')
  done < <(awk '
    /"type":"assistant"/ { turn++ }
    /"compact_boundary"[[:space:]]*:[[:space:]]*true/ ||
    /"isCompactSummary"[[:space:]]*:[[:space:]]*true/ {
      if (match($0, /"pre_compact_tokens"[[:space:]]*:[[:space:]]*[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*:[[:space:]]*/, "", s)
        print s "\t" turn
      } else {
        print "-1\t" turn
      }
    }
  ' "$tpath")

  rm -f "$turn_inputs_file"
  LC_ALL=C awk -v st="$stream_total" -v b="$boundary_total" 'BEGIN{ printf "%.6f\n", st + b }'
}
