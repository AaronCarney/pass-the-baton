#!/usr/bin/env bash
# tools/cost-compare.sh - Brief 4 headline comparison: checkpoint-threshold
# trade-off + resume-pattern cache payoff. Reuses the E8 cost engine.
set -uo pipefail
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$_SD/lib/cost-models.sh"
# shellcheck source=/dev/null
source "$_SD/lib/transcript.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-compare-model.sh"
# shellcheck source=/dev/null
source "$_SD/lib/tokens.sh"

DISCLAIMER="Token counts are an estimate computed from content size and Anthropic's published per-model tokenizer behavior. Actual API billing uses Anthropic's authoritative count, which may differ by up to ~5% on prose and up to ~35% on code or structured text for Opus 4.7. For a billing-grade figure, use \`bash tools/cost.sh --verify --corpus DIR\`."

MODEL="claude-sonnet-4-6"; TRANSCRIPT="${BATON_TRANSCRIPT_PATH:-}"; JSON=0
SUMMARY_MODEL="${BATON_SUMMARY_MODEL:-}"
SUMMARY_TOKENS="${BATON_SUMMARY_TOKENS:-}"
RIGOR='preprint'
_SUMMARY_TOKENS_SOURCE_NOTE=""
usage(){ cat <<EOF
Usage: cost-compare.sh [--transcript PATH] [--model ID] [--summary-model ID] [--summary-tokens N] [--rigor LEVEL] [--json]
Sweeps checkpoint thresholds (10-50% in 2% steps + never) for a Claude Code
session transcript and reports the cost-minimizing setting. Reads only usage
numerics.
  --summary-model ID    model that writes the resume summary (default: --model;
                        env BATON_SUMMARY_MODEL). Priced independently of
                        the session model being compared.
  --summary-tokens N    output tokens charged per /clear for that summary.
                        Default: average token count of progress files under
                        BATON_PROGRESS_DIR + BATON_ARCHIVE_DIR; falls
                        back to 2500 only when no history exists.
                        Env BATON_SUMMARY_TOKENS overrides; 0 = off.
  --rigor LEVEL         preprint|workshop|mlsys. preprint = default behavior.
                        workshop/mlsys: single-transcript CI deferred to E16.
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) TRANSCRIPT="$2"; shift 2;;
    --model)      MODEL="$2";      shift 2;;
    --json)       JSON=1;          shift 1;;
    --summary-model)  SUMMARY_MODEL="$2";  shift 2;;
    --summary-tokens) SUMMARY_TOKENS="$2"; _SUMMARY_TOKENS_SOURCE_NOTE="passed via --summary-tokens"; shift 2;;
    --rigor)      RIGOR="$2"; shift 2;;
    --help|-h)    usage; exit 0;;
    *) echo "cost-compare.sh: unknown option: $1" >&2; exit 2;;
  esac
done
case "$RIGOR" in preprint|workshop|mlsys) ;; *) echo "cost-compare.sh: invalid --rigor '$RIGOR' (expected preprint|workshop|mlsys)" >&2; exit 2;; esac
# TODO: cost-compare-cross-transcript-CI
if [ "$RIGOR" != 'preprint' ]; then
  echo "cost-compare.sh is a single-transcript tool; workshop/mlsys CI surfaces require corpus-level aggregation - use cost-sweep-corpus.sh instead. Proceeding with preprint output." >&2
fi
# Resolve summary-tokens default *after* arg parse so explicit --summary-tokens
# wins over auto-derivation. Env var override gets its own source note.
if [ -z "$SUMMARY_TOKENS" ]; then
  IFS='|' read -r SUMMARY_TOKENS _SUMMARY_TOKENS_SOURCE_NOTE < <(ccmp::derive_summary_tokens_default)
elif [ -z "$_SUMMARY_TOKENS_SOURCE_NOTE" ]; then
  _SUMMARY_TOKENS_SOURCE_NOTE="env BATON_SUMMARY_TOKENS"
fi

# resolve_id maps alias -> pinned id for DISPLAY only. The _CM_PRICE table and
# cost_of_turn are keyed by the ALIAS (mirrors E8 tools/cost.sh, which never
# resolves before computing); feeding the pinned id into cost_of_turn misses
# the price table (return 2 -> empty -> $0). Compute with $MODEL, show $_model.
_model=$(cost_models::resolve_id "$MODEL" 2>/dev/null)
_pm="$MODEL"
# Validate the model against the price table (parity with E8 tools/cost.sh):
# an unknown id would otherwise yield a confident all-$0 report + leaked stderr.
if ! cost_models::cost_of_turn "$_pm" 0 0 0 1 1 >/dev/null 2>&1; then
  echo "cost-compare.sh: unknown model: $MODEL" >&2; exit 2
fi
# Summary model defaults to the session model (back-compat: pre-addendum tests
# never pass --summary-model and must see the session-model pricing). Validate
# the resolved id against the price table using the E8 cost_of_turn guard.
: "${SUMMARY_MODEL:=$MODEL}"
if ! cost_models::cost_of_turn "$SUMMARY_MODEL" 0 0 0 1 1 >/dev/null 2>&1; then
  echo "cost-compare.sh: unknown summary model: $SUMMARY_MODEL" >&2; exit 2
fi
case "$SUMMARY_TOKENS" in
  ''|*[!0-9]*) echo "cost-compare.sh: --summary-tokens must be a non-negative integer: $SUMMARY_TOKENS" >&2; exit 2;;
esac
stream=$(transcript::turn_stream "$TRANSCRIPT")
rows=$(printf '%s\n' "$stream" | grep -c . || true)
if [ -z "$stream" ] || [ "${rows:-0}" -eq 0 ]; then
  echo "no assistant turns in transcript" >&2; exit 0
fi
# prefix = turn-1 non-output input (cr+cw5+cw1+fi) - Brief 4 §11 generalization.
prefix=$(printf '%s\n' "$stream" | ccmp::derive_prefix)

sgen=$(ccmp::summary_gen_cost "$SUMMARY_MODEL" "$SUMMARY_TOKENS")

# Cross-model summarizer-input rate (USD per input token). The summary_gen_cost
# helper charges OUTPUT only; that's the right model when the summarizer is the
# session model (the prior context is in the session's cache, sunk). When the
# user picks a DIFFERENT --summary-model, that model has not seen the prior
# context - it must consume the pre-/clear fill as fresh input at its own
# base_in. Threshold_sweep multiplies this rate by fill at each firing.
# Rate=0 when same-model (preserves pre-Addendum-A semantics) or when summaries
# are disabled (--summary-tokens 0). cached_total/breakeven_turn keep the
# OUTPUT-only sg charge; the resume-payoff figure can't know the prior session's
# context length, so input there is left intentionally unmodeled and called out
# in the cross-model caveat below.
sg_in_rate=$(ccmp::derive_sg_in_rate "$SUMMARY_MODEL" "$MODEL" "$SUMMARY_TOKENS")

unc=$(ccmp::uncached_total    "$_pm" "$prefix" "$stream")
cac=$(ccmp::cached_total      "$_pm" "$prefix" "$stream" "$sgen")
be=$(ccmp::breakeven_turn     "$_pm" "$prefix" "$stream" "$sgen")
guards=$(ccmp::payoff_guards  "$_pm" "$prefix" "$stream")
# Sweep 10-50% in 2% steps plus 'never'. The hook fires when fill ≥ T; below
# ~10% the post-/clear context already exceeds T (checkpoint thrash), above
# ~50% the session is well past Claude Code's auto-compaction point.
SWEEP_THRESHOLDS="10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 never"
sweep=$(ccmp::threshold_sweep "$_pm" "$prefix" "$stream" "$SWEEP_THRESHOLDS" "$sgen" "$sg_in_rate")
# Find the numeric threshold minimizing total cost (excludes 'never'); ties
# break to the lower threshold (smaller T checkpoints earlier - less risk of
# fill spiking past the cap before the next tool call).
rec_T=""; rec_cost=""
while IFS=$'\t' read -r T v; do
  [ "$T" = "never" ] && continue
  [ -z "$rec_T" ] && { rec_T="$T"; rec_cost="$v"; continue; }
  if LC_ALL=C awk -v a="$v" -v b="$rec_cost" 'BEGIN{exit !(a+0 < b+0)}'; then
    rec_T="$T"; rec_cost="$v"
  fi
done <<< "$sweep"
# savings = uncached - cached. Can be negative when the per-/clear summary-gen
# scalar exceeds the cache benefit (short sessions, expensive summarizer); the
# human output's summary-gen line surfaces the cause, JSON consumers see a
# signed savings_usd. Negative is the correct math, not a regression.
sav=$(LC_ALL=C awk -v u="$unc" -v c="$cac" 'BEGIN{printf "%.6f", u-c}')
savpct=$(LC_ALL=C awk -v u="$unc" -v c="$cac" 'BEGIN{ if(u+0>0) printf "%.1f",(u-c)/u*100; else printf "0.0"}')

if [ "$JSON" -eq 1 ]; then
  th_json=$(printf '%s\n' "$sweep" | awk -F'\t' 'BEGIN{printf "{"} {printf "%s\"%s\":%s",sep,$1,$2; sep=","} END{printf "}"}')
  g_json=$(printf '%s' "$guards" | tr ' ' '\n' | grep -c . >/dev/null 2>&1 && \
           printf '%s' "$guards" | awk '{n=split($0,a," "); printf "["; for(i=1;i<=n;i++){if(a[i]!=""){printf "%s\"%s\"",s,a[i];s=","}}; printf "]"}' || printf '[]')
  # JSON-escape source note (free-form string from auto-derive).
  src_note_json=$(printf '%s' "$_SUMMARY_TOKENS_SOURCE_NOTE" | jq -Rs .)
  printf '{"model":"%s","turns":%s,"prefix_tokens":%s,"summary_model":"%s","summary_tokens":%s,"summary_tokens_source":%s,"thresholds":%s,"recommended":{"threshold_pct":%s,"cost_usd":%s},"resume_payoff":{"uncached_usd":%s,"cached_usd":%s,"savings_usd":%s,"savings_pct":%s,"breakeven_turn":%s},"summary_gen_usd":%s,"summary_input_rate_usd_per_token":%s,"guards":%s}\n' \
    "$_model" "$rows" "$prefix" "$SUMMARY_MODEL" "$SUMMARY_TOKENS" "$src_note_json" "$th_json" "$rec_T" "$rec_cost" "$unc" "$cac" "$sav" "$savpct" "$be" "$sgen" "$sg_in_rate" "$g_json"
  exit 0
fi

echo "baton cost comparison - model $_model, $rows turns, prefix ${prefix} tok"
echo "─────────────────────────────────────────────────────"
echo "Checkpoint threshold → session cost (Brief 4 §3/§4):"
printf '%s\n' "$sweep" | while IFS=$'\t' read -r T v; do
  label="$T%"; [ "$T" = "never" ] && label="never (context grows)"
  marker=""; [ "$T" = "$rec_T" ] && marker="  ← cost-minimizing"
  printf '  %-26s $%s%s\n' "$label" "$v" "$marker"
done
echo "─────────────────────────────────────────────────────"
printf 'Recommended threshold for this transcript: %s%% at $%s\n' "$rec_T" "$rec_cost"
echo "─────────────────────────────────────────────────────"
echo "Resume-pattern cache payoff:"
printf '  context-grows (uncached)  $%s\n' "$unc"
printf '  clear+resume  (cached)    $%s\n' "$cac"
printf '  savings                   $%s  (%s%%)\n' "$sav" "$savpct"
printf '  summary-gen (per /clear)  $%s  (%s tok output, %s; %s)\n' "$sgen" "$SUMMARY_TOKENS" "$SUMMARY_MODEL" "$_SUMMARY_TOKENS_SOURCE_NOTE"
if LC_ALL=C awk -v r="$sg_in_rate" 'BEGIN{exit !(r+0 > 0)}'; then
  printf '  summary-input (per /clear) $%s/tok input × fill at each /clear  (cross-model: %s reads pre-/clear context)\n' \
    "$sg_in_rate" "$SUMMARY_MODEL"
fi
if [ "$be" = "0" ]; then
  echo "  break-even                never within this session"
else
  printf '  break-even                turn %s\n' "$be"
fi
[ -n "$guards" ] && echo "  caveats: $guards (savings may not hold - see Brief 4 §4)"
# cached_usd / savings model the cross-model summarizer's OUTPUT but not its
# INPUT (the resume-payoff function can't know the prior session's length).
# Threshold-sweep totals DO include the cross-model input charge per firing.
if LC_ALL=C awk -v r="$sg_in_rate" 'BEGIN{exit !(r+0 > 0)}'; then
  echo "  note: resume-payoff cached_usd excludes the cross-model summarizer's"
  echo "        input cost (modeled only in threshold-sweep totals above)."
fi
echo "─────────────────────────────────────────────────────"
echo "$DISCLAIMER"
