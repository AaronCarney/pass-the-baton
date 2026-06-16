#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib/cost-models.sh"
# shellcheck source=/dev/null
source "$DIR/lib/cost-compare-model.sh"
PASS=0; FAIL=0; FAILED=()
assert(){ local n="$1" c="$2"; if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"; else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi; }
# _aeq <expected> <actual> <name> - equality assert with PASS/FAIL counter parity.
_aeq(){ local e="$1" a="$2" n="$3"; if [ "$e" = "$a" ]; then PASS=$((PASS+1)); echo "  PASS  $n"; else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n (expected '$e' got '$a')" >&2; fi; }
# helper: float a < b  (LC_ALL=C awk, E8 locale precedent)
flt(){ LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

M=claude-opus-4-7
# 5-turn stream from Brief 4 §4 setup: prefix=18000 (8000 tools+sys + 10000 summary),
# 5 turns of u=500, o=1500. Stream rows: cr cw5 cw1 fi out (uncached-shape input here is
# irrelevant; the model recomputes input from prefix+history).
STREAM=$'0\t0\t0\t500\t1500\n0\t0\t0\t500\t1500\n0\t0\t0\t500\t1500\n0\t0\t0\t500\t1500\n0\t0\t0\t500\t1500'
PREFIX=18000

unc=$(ccmp::uncached_total "$M" "$PREFIX" "$STREAM")
cac=$(ccmp::cached_total   "$M" "$PREFIX" "$STREAM")

# Oracle 1: uncached turn-1 == cost_of_turn(M,0,0,0, 18000+500, 1500) (first-principles, NOT Brief4 $).
exp_u1=$(cost_models::cost_of_turn "$M" 0 0 0 18500 1500)
got_u1=$(ccmp::uncached_total "$M" "$PREFIX" $'0\t0\t0\t500\t1500')
assert "uncached single-turn == cost_of_turn oracle" "[ \"\$got_u1\" = \"\$exp_u1\" ]"

# Oracle 2: cached turn-1 == cost_of_turn(M,0,18000,0,500,1500)
exp_c1=$(cost_models::cost_of_turn "$M" 0 18000 0 500 1500)
got_c1=$(ccmp::cached_total "$M" "$PREFIX" $'0\t0\t0\t500\t1500')
assert "cached single-turn == cost_of_turn oracle" "[ \"\$got_c1\" = \"\$exp_c1\" ]"

# Property (Brief 4 §4): over 5 turns cached < uncached.
assert "5-turn cached < uncached" "flt \"\$cac\" \"\$unc\""

# Break-even exists and is turn 2 (Brief 4 §4: 'Break-even happens during turn 2').
be=$(ccmp::breakeven_turn "$M" "$PREFIX" "$STREAM")
assert "break-even turn == 2" "[ \"\$be\" = '2' ]"

# Threshold sweep - Brief 4 headline "low-vs-high checkpoint threshold cost".
# PREFIX=18000, 5×(u=500,o=1500): fill% after turn k = 1.8 + 0.2k  (2.0%..2.8%).
#   T=2.0 -> fires after turn 1, then re-fires (fill resets to ~prefix=1.8%,
#            +0.2% > 2.0 every turn): a too-low threshold thrashes -> still
#            < pure-uncached, but NOT monotone vs a higher T (expected, real).
#   T=10  -> fill never reaches 10%        -> pure uncached (== 'never' == unc)
# (The clean low-vs-high differentiation is asserted in Task 6 at the real
#  20/28/40 thresholds, where prefix-fill <<< T so no thrash occurs.)
sweep=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0 10 never")
val(){ printf '%s\n' "$sweep" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }
never=$(val never)
assert "sweep 'never' == uncached_total"           "[ \"\$never\" = \"\$unc\" ]"
assert "high T (never crosses fill) == uncached"   "[ \"\$(val 10)\" = \"\$unc\" ]"
assert "firing T < never (checkpointing beats never)" "flt \"\$(val 2.0)\" \"\$never\""
# production-default thresholds still emit exactly 4 rows
psweep=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "20 28 40 never")
assert "sweep emits 4 rows" "[ \"\$(printf '%s\n' \"\$psweep\" | grep -c .)\" = '4' ]"

# Payoff guard: single-turn stream flags 'single_turn'.
g=$(ccmp::payoff_guards "$M" "$PREFIX" $'0\t0\t0\t500\t1500')
assert "single-turn -> single_turn guard" "printf '%s' \"\$g\" | grep -q single_turn"
# Payoff guard: prefix below min_cache_tokens flags 'prefix_below_min'.
g2=$(ccmp::payoff_guards "$M" 100 "$STREAM")
assert "tiny prefix -> prefix_below_min guard" "printf '%s' \"\$g2\" | grep -q prefix_below_min"

# --- Addendum A: summary-generation cost (scalar; default 0 = unchanged) ----
# Regression: sg omitted/0 -> identical to pre-addendum totals.
unc0=$(ccmp::uncached_total "$M" "$PREFIX" "$STREAM")
cac0=$(ccmp::cached_total   "$M" "$PREFIX" "$STREAM")
cac0e=$(ccmp::cached_total  "$M" "$PREFIX" "$STREAM" 0)
assert "sg defaulted == sg=0 (no behavior change)" "[ \"\$cac0\" = \"\$cac0e\" ]"
# summary_gen_cost helper == cost_of_turn(model,0,0,0,0,S)  (S output tokens).
sg=$(ccmp::summary_gen_cost "$M" 2500)
sg_oracle=$(cost_models::cost_of_turn "$M" 0 0 0 0 2500)
assert "summary_gen_cost == output-token oracle" "[ \"\$sg\" = \"\$sg_oracle\" ]"
assert "summary_gen_cost S=0 -> 0.000000" "[ \"\$(ccmp::summary_gen_cost \"\$M\" 0)\" = '0.000000' ]"
# Decoupled pricing: helper takes ANY model, not the session model. A cheaper
# summary model yields a strictly smaller scalar than the session model.
sg_cheap=$(ccmp::summary_gen_cost claude-sonnet-4-6 2500)
assert "cheaper summary-model -> smaller scalar" "flt \"\$sg_cheap\" \"\$sg\""
# cached_total takes the per-/clear USD SCALAR (not tokens) and adds exactly one.
cacS=$(ccmp::cached_total "$M" "$PREFIX" "$STREAM" "$sg")
exp_cacS=$(_ccmp_add "$cac0" "$sg")
assert "cached_total adds exactly one sg scalar" "[ \"\$cacS\" = \"\$exp_cacS\" ]"
# Break-even shifts later (or to 0) when the scalar is large.
big=$(ccmp::summary_gen_cost "$M" 200000)
beS=$(ccmp::breakeven_turn "$M" "$PREFIX" "$STREAM" "$big")
be0=$(ccmp::breakeven_turn "$M" "$PREFIX" "$STREAM" 0)
assert "huge sg delays/erases break-even" "[ \"\$beS\" -ge \"\$be0\" ] || [ \"\$beS\" = '0' ]"
# threshold_sweep charges the scalar per checkpoint firing: thrash (T=2.0,
# many re-fires) with sg>0 strictly exceeds the same sweep with sg=0.
sw0=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0" 0     | awk -F'\t' '$1=="2.0"{print $2}')
swS=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0" "$sg" | awk -F'\t' '$1=="2.0"{print $2}')
assert "thrash sweep sg>0 > sg=0 (per-firing charge)" "flt \"\$sw0\" \"\$swS\""
# 'never' (uncached) never pays the scalar regardless of its value.
nv0=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "never" 0       | awk -F'\t' '$1=="never"{print $2}')
nvS=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "never" "$big"  | awk -F'\t' '$1=="never"{print $2}')
assert "never regime ignores sg" "[ \"\$nv0\" = \"\$nvS\" ] && [ \"\$nv0\" = \"\$unc0\" ]"

# --- Cross-model summarizer INPUT charge in threshold_sweep -----------------
# When --summary-model differs from --model, the summarizer reads pre-/clear
# context as fresh input billed at its own base_in. Modeled via the optional
# 6th arg sg_in_rate (USD/input-token). rate=0 (default) == same-model semantics.
sm_in_rate=$(LC_ALL=C awk -v p="$(cost_models::price claude-sonnet-4-6 base_in)" \
  'BEGIN{printf "%.12f", p/1000000}')
# Regression: 6th arg omitted == 6th arg 0.
sw_omit=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0" "$sg"           | awk -F'\t' '$1=="2.0"{print $2}')
sw_zero=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0" "$sg" 0         | awk -F'\t' '$1=="2.0"{print $2}')
assert "sg_in_rate omitted == sg_in_rate=0 (no behavior change)" "[ \"\$sw_omit\" = \"\$sw_zero\" ]"
# Cross-model rate > 0 -> firing sweep strictly larger (each firing adds fill×rate).
sw_xmodel=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "2.0" "$sg" "$sm_in_rate" | awk -F'\t' '$1=="2.0"{print $2}')
assert "cross-model sg_in_rate>0 -> sweep total higher" "flt \"\$sw_zero\" \"\$sw_xmodel\""
# 'never' regime fires no /clear -> sg_in_rate has no effect (parity with sg).
nv_xmodel=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "never" "$sg" "$sm_in_rate" | awk -F'\t' '$1=="never"{print $2}')
assert "never regime ignores sg_in_rate" "[ \"\$nv_xmodel\" = \"\$nv0\" ]"
# High threshold (10%) never crosses in this stream -> no firings -> rate ignored.
sw_no_fire_zero=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "10" "$sg" 0           | awk -F'\t' '$1=="10"{print $2}')
sw_no_fire_xm=$(ccmp::threshold_sweep "$M" "$PREFIX" "$STREAM" "10" "$sg" "$sm_in_rate" | awk -F'\t' '$1=="10"{print $2}')
assert "no-firing threshold ignores sg_in_rate" "[ \"\$sw_no_fire_zero\" = \"\$sw_no_fire_xm\" ]"

# --- E11 lift: ccmp::derive_prefix parity ---
# Definition: prefix = sum of first 4 fields of first row of TSV stream.
out=$(printf '10\t20\t30\t40\t50\n100\t100\t100\t100\t100\n' | ccmp::derive_prefix)
assert 'derive_prefix sums first-turn fields 1..4' "[ \"$out\" = '100' ]"
out=$(printf '0\t0\t0\t0\t0\n' | ccmp::derive_prefix)
assert 'derive_prefix zero stream → 0' "[ \"$out\" = '0' ]"
out=$(printf '' | ccmp::derive_prefix)
assert 'derive_prefix empty stream → empty/0 safe' "[ \"$out\" = '0' ] || [ -z \"$out\" ]"
out=$(printf '5\t0\t0\t10\t99\n9\t9\t9\t9\t9\n' | ccmp::derive_prefix)
assert 'derive_prefix only reads row 1' "[ \"$out\" = '15' ]"

# --- E11 lift: ccmp::derive_summary_tokens_default behaves identically to the
#     old _cc_derive_summary_default ---
# Source lib/tokens.sh for the file estimator the lifted helper depends on.
# shellcheck source=/dev/null
source "$DIR/lib/tokens.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Isolate XDG_STATE_HOME so the E19 state-file probe finds nothing and these
# pre-existing assertions exercise the progress-scan / 2500-fallback paths.
export XDG_STATE_HOME="$TMP/xdg-empty"
export BATON_PROGRESS_DIR="$TMP/nope" BATON_ARCHIVE_DIR="$TMP/nope2"
out=$(ccmp::derive_summary_tokens_default)
tok=$(printf '%s' "$out" | cut -d'|' -f1)
note=$(printf '%s' "$out" | cut -d'|' -f2-)
assert 'derive_summary_tokens_default no history → 2500 default' "[ \"$tok\" = '2500' ]"
assert 'derive_summary_tokens_default default note set' "printf '%s' \"$note\" | grep -q 'default'"

# With a fixture progress file, the function returns its tokens::estimate result
mkdir -p "$TMP/prog"
printf '%s\n' 'This is a fixture progress file with some prose content.' > "$TMP/prog/progress-fixture.md"
export BATON_PROGRESS_DIR="$TMP/prog"
out=$(ccmp::derive_summary_tokens_default)
tok=$(printf '%s' "$out" | cut -d'|' -f1)
assert 'derive_summary_tokens_default with file → positive integer' "[ \"$tok\" -gt 0 ]"
assert 'derive_summary_tokens_default with file → measured note' "printf '%s' \"$out\" | cut -d'|' -f2- | grep -q 'measured'"

# --- E11 lift: ccmp::derive_sg_in_rate parity ---
# Definition: returns "0" if summary_model == session_model OR
# summary_tokens<=0; else %.12f of (cost_models::price <summary_model> base_in)/1_000_000.
# Mirrors tools/cost-compare.sh:128-132 byte-for-byte.
out=$(ccmp::derive_sg_in_rate claude-sonnet-4-6 claude-sonnet-4-6 2500)
assert 'derive_sg_in_rate same model -> 0' "[ \"$out\" = '0' ]"
out=$(ccmp::derive_sg_in_rate claude-opus-4-7 claude-sonnet-4-6 0)
assert 'derive_sg_in_rate zero summary tokens -> 0' "[ \"$out\" = '0' ]"
out=$(ccmp::derive_sg_in_rate claude-opus-4-7 claude-sonnet-4-6 2500)
assert 'derive_sg_in_rate cross-model positive tokens -> 12-digit decimal' \
  "printf '%s' \"$out\" | grep -qE '^[0-9]+\\.[0-9]{12}$'"
# Identity vs producer at tools/cost-compare.sh:128-131
_om_base_in=$(cost_models::price claude-opus-4-7 base_in)
_expected=$(LC_ALL=C awk -v p="$_om_base_in" 'BEGIN{printf "%.12f", p/1000000}')
assert 'derive_sg_in_rate matches producer formula byte-for-byte' "[ \"$out\" = \"$_expected\" ]"

unset BATON_PROGRESS_DIR BATON_ARCHIVE_DIR

# E19 T7: state-file overrides progress-file scan + 2500 fallback.
STATE_DIR=$(mktemp -d)
export XDG_STATE_HOME="$STATE_DIR"
mkdir -p "$STATE_DIR/baton"
printf '{"n":12,"mean":2750,"skill_hash":"free"}\n' > "$STATE_DIR/baton/summary-tokens-mean.json"
IFS='|' read -r tokens note < <(ccmp::derive_summary_tokens_default)
_aeq '2750' "$tokens" 'state-file mean used'
case "$note" in *summary-tokens-mean.json*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: note should mention state file (got: $note)" >&2;; esac
# N-count must appear in the note (not just the path substring).
case "$note" in *'12 summary turns'*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: note should include N=12 (got: $note)" >&2;; esac

# Zero-mean state-file ({n:0, mean:0}) must fall through to progress-scan, not return 0.
printf '{"n":0,"mean":0,"skill_hash":""}\n' > "$STATE_DIR/baton/summary-tokens-mean.json"
IFS='|' read -r tokens note < <(BATON_PROGRESS_DIR=/nonexistent BATON_ARCHIVE_DIR=/nonexistent ccmp::derive_summary_tokens_default)
_aeq '2500' "$tokens" 'zero-mean state file → fall through to 2500 fallback'

# Without state-file but with progress files, fall back to progress-scan.
rm -f "$STATE_DIR/baton/summary-tokens-mean.json"
# (Existing progress-file scan assertions in the test file already cover that path; ensure they still pass.)
# Without state-file and without progress files, fall back to 2500.
IFS='|' read -r tokens note < <(BATON_PROGRESS_DIR=/nonexistent BATON_ARCHIVE_DIR=/nonexistent ccmp::derive_summary_tokens_default)
_aeq '2500' "$tokens" 'final fallback 2500'
case "$note" in *'(no recorded progress files found)'*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: 2500 fallback note unexpected: $note" >&2;; esac

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
