#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-models.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-compact.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-automemory.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-clear-only.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/cost-model-none.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/transcript.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/replay-harness.sh"

# Fixture: 3-turn transcript on sonnet-4-6 (matches the E13a test math).
FIXTURE="$(mktemp -d)"
T="$FIXTURE/3turn.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$T"

# === Test: transcript::ctx_out_stream - projects 5-col turn_stream → 2-col ctx<TAB>out ===
# Run it on the existing 3-turn fixture T (turn_stream emits 5 cols; ctx_out_stream
# should emit exactly 2 cols per row: input_tokens<TAB>output_tokens).
rows="$(transcript::ctx_out_stream "$T")"
row1="$(echo "$rows" | sed -n '1p')"
row2="$(echo "$rows" | sed -n '2p')"
row3="$(echo "$rows" | sed -n '3p')"
row_count="$(printf '%s\n' "$rows" | wc -l | awk '{print $1}')"
assert "ctx_out_stream emits 3 rows for 3-turn fixture" "[ \"$row_count\" = '3' ]"
assert "ctx_out_stream row1 = 10000<TAB>1000" "[ \"$row1\" = $'10000\t1000' ]"
assert "ctx_out_stream row2 = 25000<TAB>2000" "[ \"$row2\" = $'25000\t2000' ]"
assert "ctx_out_stream row3 = 40000<TAB>1500" "[ \"$row3\" = $'40000\t1500' ]"

# === Test: replay_harness::none_total over 3-turn fixture ===
# Identical to E13a's cost_model_none::trajectory_cost test on same numbers → 0.292500
cost="$(replay_harness::none_total claude-sonnet-4-6 "$T")"
assert "none_total over 3-turn fixture" "[ \"$cost\" = '0.292500' ]"

# === Test: replay_harness::clear_only_total - 3 turns, /clear after turn 2 ===
# Construct a fixture where turn 3 is preceded by a `/clear` event.
# clear_event_cost=0 (per arm); per-turn cost equals none arm because clear-only
# doesn't change the cost math, it just resets the cache state which the none arm
# doesn't track anyway. So clear_only_total on this fixture = none_total on it.
T_CLEAR="$FIXTURE/3turn-clear.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"user","message":{"content":"/clear"}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$T_CLEAR"
cost="$(replay_harness::clear_only_total claude-sonnet-4-6 "$T_CLEAR")"
assert "clear_only_total over 3-turn /clear fixture (= none_total: 0.292500)" "[ \"$cost\" = '0.292500' ]"

# === Test: rc=1 on missing transcript ===
set +e
replay_harness::clear_only_total claude-sonnet-4-6 /nonexistent/path.jsonl >/dev/null 2>&1
rc=$?
set -e
assert "clear_only_total: missing transcript → rc=1" "[ \"$rc\" = '1' ]"

# === Test (nc=0): replay_harness::automemory_total - 3 turns, 5000 automemory tokens ===
# First turn: pays automemory event_cost first (5000 * r_cw_5m / 1e6 = 0.018750)
#             + cost_model_none::turn_cost (10000*3 + 1000*15)/1e6 = 0.045000
# Turn 2: pays automemory within-ttl (5000 * r_cr / 1e6 = 0.001500)
#         + none turn (25000*3 + 2000*15)/1e6 = 0.105000
# Turn 3: pays automemory within-ttl (0.001500)
#         + none turn (40000*3 + 1500*15)/1e6 = 0.142500
# Total = 0.018750 + 0.045000 + 0.001500 + 0.105000 + 0.001500 + 0.142500 = 0.314250
cost="$(replay_harness::automemory_total claude-sonnet-4-6 "$T" 5000)"
assert "automemory_total over 3-turn fixture (nc=0), 5k automem tokens" "[ \"$cost\" = '0.314250' ]"

# === Test (nc=1): live exercise of the (n-1-nc)*within term in the surcharge formula ===
# Build the same 3-turn-plus-1-compact-event fixture used later by Step 15 (T_COMPACT).
# Verify nc=1 (transcript::compact_events emits one boundary).
T_COMPACT_INLINE="$FIXTURE/3turn-compact-inline.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":35000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$T_COMPACT_INLINE"
# stream_total (same 3 assistant turns as T) = 0.292500
# n_turns=3, nc=1 (one compact_boundary line). Per the surcharge formula:
#   surcharge = first + (n - 1 - nc) * within = 0.018750 + (3 - 1 - 1) * 0.001500
#             = 0.018750 + 1 * 0.001500 = 0.020250
# Total = stream_total + surcharge = 0.292500 + 0.020250 = 0.312750
cost="$(replay_harness::automemory_total claude-sonnet-4-6 "$T_COMPACT_INLINE" 5000)"
assert "automemory_total nc=1 (live (n-1-nc)*within exercised)" "[ \"$cost\" = '0.312750' ]"

# === Test: rc=1 on non-integer automemory_tokens ===
set +e
replay_harness::automemory_total claude-sonnet-4-6 "$T" not-a-num >/dev/null 2>&1
rc=$?
set -e
assert "automemory_total: non-integer tokens → rc=1" "[ \"$rc\" = '1' ]"

# === Test: replay_harness::compact_total - 3 turns, no compact boundaries ===
# With zero compact events, compact_total == none_total (no surcharge)
cost="$(replay_harness::compact_total claude-sonnet-4-6 "$T")"
assert "compact_total with no compact boundaries == none_total (0.292500)" "[ \"$cost\" = '0.292500' ]"

# === Test: compact_total over fixture with one /compact boundary after turn 2 ===
# Build fixture: 3 turns + one synthetic compact_boundary marker after turn 2.
T_COMPACT="$FIXTURE/3turn-compact.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":35000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$T_COMPACT"
# Per-turn baseline = 0.292500 (same 3 assistant turns as fixture T).
# One compact event at warm cache, P=35000 (read from compact_boundary line):
#   Sys=20000, Sys+P=55000, S=clamp(0.10*35000,2K,20K)=3500
#   warm = 55000*0.30 + 1100*3.00 + 3500*15.00 + 3500*3.75 = 16500+3300+52500+13125 = 85425 → 0.085425
# Total = 0.292500 + 0.085425 = 0.377925
cost="$(replay_harness::compact_total claude-sonnet-4-6 "$T_COMPACT")"
assert "compact_total with one warm /compact boundary at P=35000" "[ \"$cost\" = '0.377925' ]"

# === Test: compact_total - fallback path (compact_boundary WITHOUT pre_compact_tokens) ===
# ASYMMETRIC from T_COMPACT (turn 1 input is 30000 here vs. 25000 in T_COMPACT).
# This makes fallback P = 10000 + 30000 = 40000 (vs. T_COMPACT's synthetic P=35000),
# so the warm compact cost differs (0.096300 vs. 0.085425) and the assert proves the
# fallback compute path was actually executed correctly (not coincidentally agreeing
# with the synthetic path).
T_COMPACT_FALLBACK="$FIXTURE/3turn-compact-fallback.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":30000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"system","message":{"isCompactSummary":true}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":40000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$T_COMPACT_FALLBACK"
cost="$(replay_harness::compact_total claude-sonnet-4-6 "$T_COMPACT_FALLBACK")"
assert "compact_total fallback (asymmetric, P=40000 sum-prior path) = 0.403800" "[ \"$cost\" = '0.403800' ]"

# === Test (nc>=n pathological): automemory_total clamp - n=1 turn, nc=1 compact boundary ===
# When nc >= n the unguarded formula (n - 1 - nc) goes negative → surcharge underflows.
# After the clamp: within_n = max(0, 1-1-1) = 0, so only the 'first' charge applies.
# Rates (claude-sonnet-4-6): cache_write_5m=3.75/MTok → first = 5000*3.75/1e6 = 0.018750
# stream_total = (10000*3 + 1000*15)/1e6 = 0.045000
# Expected = 0.045000 + 0.018750 = 0.063750
T_PATHOLOGICAL="$FIXTURE/1turn-1compact.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":10000}}' \
  > "$T_PATHOLOGICAL"
cost="$(replay_harness::automemory_total claude-sonnet-4-6 "$T_PATHOLOGICAL" 5000)"
assert "automemory_total nc>=n pathological (n=1,nc=1) clamps to first only = 0.063750" "[ \"$cost\" = '0.063750' ]"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
