#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$DIR/tools/cost-compare.sh"
PASS=0; FAIL=0; FAILED=()
assert(){ local n="$1" c="$2"; if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"; else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi; }

t=$(mktemp -d)
# Hermetic: pin progress + archive dirs to non-existent paths so the
# summary-tokens auto-derive (added 2026-05-19) hits the 2500 fallback and
# does not pick up the developer's real progress history when running the
# suite locally. New asserts below opt in to a fake history when needed.
export BATON_PROGRESS_DIR="$t/no-history-progress"
export BATON_ARCHIVE_DIR="$t/no-history-archive"
# E19 T7: the auto-derive now probes a state file at
# $XDG_STATE_HOME/baton/summary-tokens-mean.json before the
# progress scan. Pin it to an empty dir so the suite ignores the developer's
# real running-mean state and exercises the progress-scan/2500 fallbacks.
export XDG_STATE_HOME="$t/no-history-state"
# 5 assistant turns, prefix-ish first turn writes 18000, then growing reads.
{
  echo '{"type":"user","message":{"role":"user","content":"x"}}'
  echo '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":18000,"input_tokens":500,"output_tokens":1500}}}'
  for i in 1 2 3 4; do
    echo '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"cache_read_input_tokens":18000,"input_tokens":500,"output_tokens":1500}}}'
  done
} > "$t/s.jsonl"

assert "syntax ok" "bash -n '$SCRIPT'"
assert "--help exits 0" "bash '$SCRIPT' --help >/dev/null 2>&1"

out=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 2>/dev/null)
assert "human output has threshold table header" "printf '%s' \"\$out\" | grep -qi 'threshold'"
assert "human output shows 28% sweep row"       "printf '%s' \"\$out\" | grep -q '28'"
assert "human output shows 'never' row"         "printf '%s' \"\$out\" | grep -qi 'never'"
assert "human output has resume payoff savings"  "printf '%s' \"\$out\" | grep -qi 'savings'"
assert "human output carries CC6 disclaimer"     "printf '%s' \"\$out\" | grep -q 'estimate computed from content size'"

j=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --json 2>/dev/null)
assert "json parses"                  "printf '%s' \"\$j\" | jq -e . >/dev/null 2>&1"
assert "json has resume_payoff.savings_usd" "printf '%s' \"\$j\" | jq -e '.resume_payoff.savings_usd' >/dev/null 2>&1"
assert "json breakeven_turn == 2"     "[ \"\$(printf '%s' \"\$j\" | jq -r '.resume_payoff.breakeven_turn')\" = '2' ]"
assert "json thresholds.never numeric" "printf '%s' \"\$j\" | jq -e '.thresholds.never|type==\"number\"' >/dev/null 2>&1"
assert "json cached < uncached" "printf '%s' \"\$j\" | jq -e '.resume_payoff.cached_usd < .resume_payoff.uncached_usd' >/dev/null 2>&1"

empty=$(mktemp); : > "$empty"
bash "$SCRIPT" --transcript "$empty" --model claude-opus-4-7 >/dev/null 2>&1
rc=$?    # capture immediately - assert's own `local` would clobber $? if read lazily
assert "empty transcript exits 0" "[ \$rc -eq 0 ]"

# NOTE: shared-fixture cleanup is intentionally NOT here. Tasks 4 and 6 append
# blocks that reuse $t (and add $e). The single cleanup + results lines live at
# the very end of the file (added in Task 6 Step 1). Do not add `rm -rf` here.
# --- cost.sh --compare delegates to cost-compare.sh -------------------------
COST="$DIR/tools/cost.sh"
dout=$(bash "$COST" --compare --transcript "$t/s.jsonl" --model claude-opus-4-7 2>/dev/null)
assert "cost.sh --compare emits comparison output" "printf '%s' \"\$dout\" | grep -qi 'Resume-pattern cache payoff'"
assert "cost.sh --compare carries CC6 disclaimer"  "printf '%s' \"\$dout\" | grep -q 'estimate computed from content size'"

# --- e2e: Sonnet default model, larger synthetic session -------------------
e=$(mktemp -d)
{
  echo '{"type":"user","message":{"role":"user","content":"go"}}'
  echo '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":12000,"input_tokens":800,"output_tokens":2000}}}'
  for i in $(seq 1 9); do
    echo '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"cache_read_input_tokens":12000,"input_tokens":800,"output_tokens":2000}}}'
  done
} > "$e/big.jsonl"
ej=$(bash "$SCRIPT" --transcript "$e/big.jsonl" --json 2>/dev/null)
assert "e2e json parses"                "printf '%s' \"\$ej\" | jq -e . >/dev/null 2>&1"
assert "e2e 10 turns"                   "[ \"\$(printf '%s' \"\$ej\" | jq -r '.turns')\" = '10' ]"
assert "e2e cached < uncached"          "printf '%s' \"\$ej\" | jq -e '.resume_payoff.cached_usd < .resume_payoff.uncached_usd' >/dev/null 2>&1"
assert "e2e default model is sonnet"    "printf '%s' \"\$ej\" | jq -e '.model|startswith(\"claude-sonnet-4-6\")' >/dev/null 2>&1"
assert "e2e no spurious guards"         "[ \"\$(printf '%s' \"\$ej\" | jq -r '.guards|length')\" = '0' ]"

# --- e2e: production thresholds 20/28/40 actually differentiate -------------
# Large fixture so cumulative fill crosses real thresholds within 10 turns.
# prefix = turn1 (cr0+cw50000+cw1_0+fi2000) = 52000; hist += 2000+25000 = 27000/turn.
# cumulative = 52000 + 27000k -> 20% (200k) ~turn6, 28% (280k) ~turn9, 40% never.
b=$(mktemp -d)
{
  echo '{"type":"user","message":{"role":"user","content":"go"}}'
  echo '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":50000,"input_tokens":2000,"output_tokens":25000}}}'
  for i in $(seq 1 9); do
    echo '{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"cache_read_input_tokens":50000,"input_tokens":2000,"output_tokens":25000}}}'
  done
} > "$b/big.jsonl"
bj=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --json 2>/dev/null)
t20=$(printf '%s' "$bj" | jq -r '.thresholds["20"]')
t40=$(printf '%s' "$bj" | jq -r '.thresholds["40"]')
tnv=$(printf '%s' "$bj" | jq -r '.thresholds.never')
flt(){ LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }
assert "prod sweep: low T (20) < high T (40)"     "flt \"\$t20\" \"\$t40\""
assert "prod sweep: T=40 never crosses == never"  "[ \"\$t40\" = \"\$tnv\" ]"
assert "prod sweep: low T (20) < never"           "flt \"\$t20\" \"\$tnv\""

# --- unknown model -> exit 2 + stderr (E8 contract parity, no silent $0) ----
bash "$SCRIPT" --transcript "$t/s.jsonl" --model bogus-model >/dev/null 2>&1
rc=$?
assert "unknown model exits 2" "[ \$rc -eq 2 ]"
emsg=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model bogus-model 2>&1 >/dev/null)
assert "unknown model reports to stderr" "printf '%s' \"\$emsg\" | grep -qi 'unknown model'"

# --- Addendum A: --summary-model + --summary-tokens surfaced + applied ------
# Defaults: summary-model unset -> echoes session model; summary-tokens 2500.
js=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --json 2>/dev/null)
assert "json has summary_model (defaults to session model)" \
  "[ \"\$(printf '%s' \"\$js\" | jq -r '.summary_model')\" = 'claude-opus-4-7' ]"
assert "json has summary_tokens (default >0)" \
  "[ \"\$(printf '%s' \"\$js\" | jq -r '.summary_tokens')\" -gt 0 ]"
assert "json has summary_gen_usd > 0 by default" \
  "printf '%s' \"\$js\" | jq -e '.summary_gen_usd > 0' >/dev/null 2>&1"
# --summary-tokens 0 -> scalar collapses; cached_usd is sg=0 reference.
j0=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-tokens 0 --json 2>/dev/null)
assert "--summary-tokens 0 -> summary_gen_usd == 0" \
  "printf '%s' \"\$j0\" | jq -e '.summary_gen_usd == 0' >/dev/null 2>&1"
# Larger summary-tokens -> larger cached_usd (scalar added once per /clear).
jD=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-tokens 4000 --json 2>/dev/null)
c0=$(printf '%s' "$j0" | jq -r '.resume_payoff.cached_usd')
cD=$(printf '%s' "$jD" | jq -r '.resume_payoff.cached_usd')
assert "S=0 cached < S=4000 cached (gen charged)" "flt \"\$c0\" \"\$cD\""
# Decoupled pricing: --summary-model overrides session model for sg only.
# Session Opus + summary Sonnet -> strictly smaller summary_gen_usd than
# session Opus + summary Opus. summary_model field echoes the override.
jOO=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-model claude-opus-4-7 --summary-tokens 2500 --json 2>/dev/null)
jOS=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-model claude-sonnet-4-6 --summary-tokens 2500 --json 2>/dev/null)
sgOO=$(printf '%s' "$jOO" | jq -r '.summary_gen_usd')
sgOS=$(printf '%s' "$jOS" | jq -r '.summary_gen_usd')
assert "cheaper --summary-model -> smaller summary_gen_usd" "flt \"\$sgOS\" \"\$sgOO\""
assert "--summary-model echoed in json" \
  "[ \"\$(printf '%s' \"\$jOS\" | jq -r '.summary_model')\" = 'claude-sonnet-4-6' ]"
# Cheaper summary-model also yields strictly smaller cached_usd at fixed S>0
# (the only path through which sg enters the resume-payoff total).
ccOO=$(printf '%s' "$jOO" | jq -r '.resume_payoff.cached_usd')
ccOS=$(printf '%s' "$jOS" | jq -r '.resume_payoff.cached_usd')
assert "cheaper --summary-model -> smaller cached_usd" "flt \"\$ccOS\" \"\$ccOO\""
# Uncached_usd ignores sg under any summary settings (regime invariant).
jBig=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-tokens 200000 --json 2>/dev/null)
uBig=$(printf '%s' "$jBig" | jq -r '.resume_payoff.uncached_usd')
u0=$(printf '%s'   "$j0"   | jq -r '.resume_payoff.uncached_usd')
assert "uncached_usd ignores sg" "[ \"\$uBig\" = \"\$u0\" ]"
# Human line surfaces tokens AND summary-model id.
hu=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-model claude-sonnet-4-6 --summary-tokens 2500 2>/dev/null)
assert "human shows summary-gen line" "printf '%s' \"\$hu\" | grep -qi 'summary-gen'"
assert "human shows S tokens"          "printf '%s' \"\$hu\" | grep -q '2500 tok'"
assert "human shows summary-model id"  "printf '%s' \"\$hu\" | grep -q 'claude-sonnet-4-6'"
# Validation: bad/missing summary-tokens and unknown summary-model -> exit 2.
assert "bad --summary-tokens rejected (exit 2)" \
  "! bash \"\$SCRIPT\" --transcript \"\$t/s.jsonl\" --summary-tokens nope >/dev/null 2>&1"
assert "unknown --summary-model rejected (exit 2)" \
  "! bash \"\$SCRIPT\" --transcript \"\$t/s.jsonl\" --summary-model not-a-model >/dev/null 2>&1"
# Usage lists both flags.
assert "usage lists --summary-model"  "bash \"\$SCRIPT\" --help 2>&1 | grep -q -- '--summary-model'"
assert "usage lists --summary-tokens" "bash \"\$SCRIPT\" --help 2>&1 | grep -q -- '--summary-tokens'"

# --- Cross-model summarizer INPUT charge surfaces in threshold sweep --------
# Same-model: summary_input_rate_usd_per_token == 0 (input is sunk in session cache).
# Cross-model: rate > 0; threshold_sweep totals strictly higher than same-model
# at any threshold whose firings actually fire (fill crosses T at least once).
# Resume-payoff cached_usd is INTENTIONALLY unchanged - prior-session length
# unknown to that function - and the human-output caveat documents this.
assert "json summary_input_rate == 0 when same-model" \
  "[ \"\$(printf '%s' \"\$js\" | jq -r '.summary_input_rate_usd_per_token')\" = '0' ]"
# jOS (cross-model) on small fixture: thresholds 20/28/40 never fire (cumulative
# fill stays < 3%); test field exists and is > 0.
assert "json summary_input_rate > 0 when cross-model" \
  "printf '%s' \"\$jOS\" | jq -e '.summary_input_rate_usd_per_token > 0' >/dev/null 2>&1"
# Big fixture ($b/big.jsonl) DOES fire at T=20 -> cross-model sweep > same-model.
bjOO=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --summary-model claude-opus-4-7  --summary-tokens 2500 --json 2>/dev/null)
bjOS=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --summary-model claude-sonnet-4-6 --summary-tokens 2500 --json 2>/dev/null)
sw_bOO_20=$(printf '%s' "$bjOO" | jq -r '.thresholds["20"]')
sw_bOS_20=$(printf '%s' "$bjOS" | jq -r '.thresholds["20"]')
assert "cross-model adds input charge -> T=20 sweep total higher"  "flt \"\$sw_bOO_20\" \"\$sw_bOS_20\""
# T=40 never fires on this fixture (max fill ~21%) -> sweep parity across both runs.
sw_bOO_40=$(printf '%s' "$bjOO" | jq -r '.thresholds["40"]')
sw_bOS_40=$(printf '%s' "$bjOS" | jq -r '.thresholds["40"]')
assert "no-firing threshold parity across summary-model choice"    "[ \"\$sw_bOO_40\" = \"\$sw_bOS_40\" ]"
# Human-output caveat surfaces when cross-model.
huX=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --summary-model claude-sonnet-4-6 --summary-tokens 2500 2>/dev/null)
assert "human cross-model output mentions summary-input"   "printf '%s' \"\$huX\" | grep -qi 'summary-input'"
assert "human cross-model output flags cached_usd caveat"  "printf '%s' \"\$huX\" | grep -qi 'cached_usd excludes'"
# Same-model: caveat suppressed.
huS=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --summary-model claude-opus-4-7  --summary-tokens 2500 2>/dev/null)
assert "human same-model output suppresses summary-input"   "! printf '%s' \"\$huS\" | grep -qi 'summary-input'"
# --summary-tokens 0 disables both output and input charges regardless of model choice.
bj0X=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 --summary-model claude-sonnet-4-6 --summary-tokens 0 --json 2>/dev/null)
assert "tokens=0 cross-model still rate==0" \
  "[ \"\$(printf '%s' \"\$bj0X\" | jq -r '.summary_input_rate_usd_per_token')\" = '0' ]"

# --- Deterministic --summary-tokens auto-derive (2026-05-19) ---------------
# (a) Empty history → falls back to 2500 (covered implicitly above; assert
#     explicitly here via the JSON source-note for clarity).
empty_src=$(printf '%s' "$js" | jq -r '.summary_tokens_source')
assert "auto-derive: empty history → source note flags fallback" \
  "printf '%s' \"\$empty_src\" | grep -qi 'no recorded progress files'"
assert "auto-derive: empty history → summary_tokens == 2500" \
  "[ \"\$(printf '%s' \"\$js\" | jq -r '.summary_tokens')\" = '2500' ]"
# (b) Fake history → derived value reflects the on-disk files.
hist=$(mktemp -d)
# Write two progress files of known prose-byte sizes. lib/tokens.sh uses
# BYTES_PER_TOKEN_PROSE=4.0 → expected ~= bytes/4. Sizes: 4000 and 6000 bytes.
head -c 4000 /dev/zero | tr '\0' 'a' > "$hist/progress-fake1.md"
head -c 6000 /dev/zero | tr '\0' 'b' > "$hist/progress-fake2.md"
hj=$(BATON_PROGRESS_DIR="$hist" BATON_ARCHIVE_DIR="/var/empty/never" \
  bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --json 2>/dev/null)
hsrc=$(printf '%s' "$hj" | jq -r '.summary_tokens_source')
htok=$(printf '%s' "$hj" | jq -r '.summary_tokens')
# Expected per-file: 4000/4 = 1000, 6000/4 = 1500. Avg = 1250.
assert "auto-derive: recorded files → source note cites count"   "printf '%s' \"\$hsrc\" | grep -qE 'measured average over 2'"
assert "auto-derive: derived value matches measured avg (1250)" "[ \"\$htok\" = '1250' ]"
rm -rf "$hist"
# (c) Explicit --summary-tokens overrides auto-derive.
xj=$(BATON_PROGRESS_DIR="$hist" \
  bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --summary-tokens 4242 --json 2>/dev/null)
assert "explicit --summary-tokens wins over auto-derive" \
  "[ \"\$(printf '%s' \"\$xj\" | jq -r '.summary_tokens')\" = '4242' ]"
assert "explicit --summary-tokens source-note flags CLI" \
  "printf '%s' \"\$xj\" | jq -r '.summary_tokens_source' | grep -qi 'passed via'"

# --- Finer sweep + cost-minimizing recommendation -------------------------
assert "sweep includes 2%-step thresholds (10..50)" \
  "printf '%s' \"\$bj\" | jq -e '.thresholds[\"10\"] and .thresholds[\"24\"] and .thresholds[\"50\"]' >/dev/null 2>&1"
assert "recommended.threshold_pct present in JSON" \
  "printf '%s' \"\$bj\" | jq -e '.recommended.threshold_pct' >/dev/null 2>&1"
assert "recommended.cost_usd present in JSON" \
  "printf '%s' \"\$bj\" | jq -e '.recommended.cost_usd' >/dev/null 2>&1"
# Recommended cost <= cost at every other numeric threshold.
rec_cost=$(printf '%s' "$bj" | jq -r '.recommended.cost_usd')
all_le=$(printf '%s' "$bj" | jq -r --arg rc "$rec_cost" \
  '.thresholds | to_entries | map(select(.key != "never")) | map(.value >= ($rc|tonumber)) | all')
assert "recommended is the cost-minimum across numeric thresholds" "[ '$all_le' = 'true' ]"
# Human output surfaces the recommendation line.
huR=$(bash "$SCRIPT" --transcript "$b/big.jsonl" --model claude-opus-4-7 2>/dev/null)
assert "human output includes 'Recommended threshold'" \
  "printf '%s' \"\$huR\" | grep -q 'Recommended threshold'"

# --- --rigor parse-only (T5) ------------------------------------------------
# workshop/mlsys: parse succeeds (exit 0) + stderr note about single-transcript.
err_w=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --rigor workshop --json 2>&1 >/dev/null) || true
assert '--rigor workshop: exit 0' \
  "bash \"\$SCRIPT\" --transcript \"\$t/s.jsonl\" --model claude-opus-4-7 --rigor workshop --json >/dev/null 2>/dev/null"
assert '--rigor workshop: stderr mentions single-transcript' \
  "printf '%s' \"\$err_w\" | grep -qi 'single-transcript'"
err_m=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --rigor mlsys --json 2>&1 >/dev/null) || true
assert '--rigor mlsys: exit 0' \
  "bash \"\$SCRIPT\" --transcript \"\$t/s.jsonl\" --model claude-opus-4-7 --rigor mlsys --json >/dev/null 2>/dev/null"
assert '--rigor mlsys: stderr mentions single-transcript' \
  "printf '%s' \"\$err_m\" | grep -qi 'single-transcript'"
# preprint = existing behavior (no stderr note).
err_p=$(bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --rigor preprint --json 2>&1 >/dev/null) || true
assert '--rigor preprint: exit 0' \
  "bash \"\$SCRIPT\" --transcript \"\$t/s.jsonl\" --model claude-opus-4-7 --rigor preprint --json >/dev/null 2>/dev/null"
assert '--rigor preprint: no single-transcript note' \
  "! printf '%s' \"\$err_p\" | grep -qi 'single-transcript'"
# invalid --rigor value exits non-zero.
bash "$SCRIPT" --transcript "$t/s.jsonl" --model claude-opus-4-7 --rigor bogus >/dev/null 2>/dev/null; rc_bogus=$?
assert '--rigor bogus: exits non-zero' "[ \"\$rc_bogus\" -ne 0 ]"

rm -rf "$t" "$empty" "$e" "$b"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
