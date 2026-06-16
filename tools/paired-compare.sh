#!/usr/bin/env bash
# tools/paired-compare.sh - paired-difference reporting: Wilcoxon + studentized bootstrap CI.
# Supports --subset clean|fired|both (default clean).
# fired subset: MSM-Γ per-arm bounds via lib/gamma-bands.sh; no point CI per L0 B11.
# log-cost paired diffs default (F10/L0 A5 line 74); --no-log-diffs to opt out.
set -uo pipefail
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO="$(cd "$_SD/.." && pwd)"
source "$_REPO/lib/stats-bootstrap.sh"

# F3: pre-req chain for gamma_bands::caveat (delegates to aggregator_v2::cc12_caveat).
[ -f "$_REPO/lib/transcript.sh" ] && source "$_REPO/lib/transcript.sh"
[ -f "$_REPO/lib/subset-stratify.sh" ] && source "$_REPO/lib/subset-stratify.sh"
[ -f "$_REPO/lib/aggregator-v2.sh" ] && source "$_REPO/lib/aggregator-v2.sh"
[ -f "$_REPO/lib/gamma-bands.sh" ] && source "$_REPO/lib/gamma-bands.sh"

_usage() {
  cat <<'EOF'
Usage: tools/paired-compare.sh --arm-a A.jsonl --arm-b B.jsonl [OPTIONS]

Inputs: JSONL where each line is {"<key>": str, "value": float, "transcript_path": str}.
Join is inner on KEY.

Options:
  --arm-a PATH         JSONL for method A (required)
  --arm-b PATH         JSONL for method B (required)
  --key NAME           Join key (default: slug)
  --n-resamples N      Bootstrap resamples for CI (default 5000)
  --alpha A            Significance level (default 0.05)
  --seed S             RNG seed
  --json               Emit JSON (default; reserved for future text mode)
  --subset MODE        clean|fired|both (default clean). 'fired' = compaction-fired subset; emits
                       per-arm gamma-band sweep via lib/gamma-bands.sh - no point CI per L0 B11.
  --gamma-min G        MSM Γ lower bound for fired subset (default 1.5 per L0 line 101)
  --gamma-max G        MSM Γ upper bound (default 3.0)
  --no-log-diffs       Disable log-cost paired diffs (default ON per L0 A5 line 74)
EOF
}

ARM_A=''; ARM_B=''; KEY='slug'; N=5000; ALPHA=0.05; SEED_OPT=''
SUBSET='clean'   # one of clean|fired|both
GAMMA_MIN='1.5'  # B11 starting range (L0 line 101)
GAMMA_MAX='3.0'
LOG_DIFFS='1'    # F10: log-cost paired diffs DEFAULT per L0 A5 line 74
while [ $# -gt 0 ]; do
  case "$1" in
    --arm-a) ARM_A="$2"; shift 2;;
    --arm-b) ARM_B="$2"; shift 2;;
    --key) KEY="$2"; shift 2;;
    --n-resamples) N="$2"; shift 2;;
    --alpha) ALPHA="$2"; shift 2;;
    --seed) SEED_OPT="$2"; shift 2;;
    --json) shift;;
    --subset) SUBSET="$2"; shift 2;;
    --gamma-min) GAMMA_MIN="$2"; shift 2;;
    --gamma-max) GAMMA_MAX="$2"; shift 2;;
    --no-log-diffs) LOG_DIFFS='0'; shift;;
    -h|--help) _usage; exit 0;;
    *) echo "paired-compare: unknown flag '$1'" >&2; _usage >&2; exit 1;;
  esac
done

case "$SUBSET" in clean|fired|both) ;; *) echo "paired-compare: invalid --subset '$SUBSET'" >&2; exit 1;; esac

if [ -z "$ARM_A" ] || [ -z "$ARM_B" ]; then
  _usage >&2; exit 1
fi

[ -f "$ARM_A" ] || { echo "paired-compare: --arm-a file not found: $ARM_A" >&2; exit 1; }
[ -f "$ARM_B" ] || { echo "paired-compare: --arm-b file not found: $ARM_B" >&2; exit 1; }

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Build paired rows with transcript_path; emit to a JSON file with join metadata.
jq -n --slurpfile arm_a "$ARM_A" --slurpfile arm_b "$ARM_B" --arg key "$KEY" '
  ($arm_a | map({(.[$key]): .}) | add // {}) as $A
  | ($arm_b | map({(.[$key]): .}) | add // {}) as $B
  | ($A | keys_unsorted) as $keysA | ($B | keys_unsorted) as $keysB
  | ($keysA - $keysB) as $only_a | ($keysB - $keysA) as $only_b
  | ($keysA - $only_a) as $common
  | {only_a:$only_a, only_b:$only_b,
     rows: ($common | map({key: ., value_a: $A[.].value, value_b: $B[.].value,
                            transcript_path: ($A[.].transcript_path // $B[.].transcript_path // "")}))}
' > "$WORKDIR/joined.json"

N_COMMON=$(jq '.rows | length' "$WORKDIR/joined.json")
if [ "$N_COMMON" -lt 1 ]; then
  jq -n '{error: "no paired observations after inner join"}'
  exit 1
fi

ONLY_A=$(jq -c '.only_a' "$WORKDIR/joined.json")
ONLY_B=$(jq -c '.only_b' "$WORKDIR/joined.json")

# Classify each row's transcript via subset_stratify::compaction_fired.
PAIRED_JSONL="$WORKDIR/paired.jsonl"
jq -c '.rows[]' "$WORKDIR/joined.json" | while read -r row; do
  tp=$(jq -r '.transcript_path // empty' <<<"$row")
  cf=0
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    cf=$(subset_stratify::compaction_fired "$tp" 2>/dev/null) || cf=0
  fi
  jq -c --argjson cf "$cf" '. + {fired:$cf}' <<<"$row"
done > "$PAIRED_JSONL"

# Partition into clean/fired diff streams (log-cost diffs by default per F10).
CLEAN_VALS="$WORKDIR/clean_vals.txt"
FIRED_VALS="$WORKDIR/fired_vals.txt"
if [ "$LOG_DIFFS" = '1' ]; then
  jq -r 'select(.fired == 0 and .value_a > 0 and .value_b > 0) | ((.value_a | log) - (.value_b | log))' "$PAIRED_JSONL" > "$CLEAN_VALS"
  jq -r 'select(.fired == 1 and .value_a > 0 and .value_b > 0) | ((.value_a | log) - (.value_b | log))' "$PAIRED_JSONL" > "$FIRED_VALS"
else
  jq -r 'select(.fired == 0) | (.value_a - .value_b)' "$PAIRED_JSONL" > "$CLEAN_VALS"
  jq -r 'select(.fired == 1) | (.value_a - .value_b)' "$PAIRED_JSONL" > "$FIRED_VALS"
fi

# _clean_block: Wilcoxon + studentized-CI body inlined verbatim (F4).
_clean_block() {
  local vals="$1" missing_a="$2" missing_b="$3"
  local n_paired; n_paired=$(grep -c . "$vals" 2>/dev/null || true)
  n_paired=${n_paired:-0}
  if [ "$n_paired" -lt 1 ]; then
    jq -n --argjson ma "$missing_a" --argjson mb "$missing_b" \
      '{n_paired:0, mean_diff:null, wilcoxon:null, ci:null, missing_from_a:$ma, missing_from_b:$mb}'
    return
  fi
  local mean_diff; mean_diff=$(awk '{s+=$1; n++} END{if(n) print s/n; else print 0}' "$vals")

  # Wilcoxon via inline Python (scipy.stats.wilcoxon) - verbatim from original tool.
  local wilcoxon
  wilcoxon=$(python3 -c '
import sys, json
import numpy as np
from scipy import stats as sps
diffs = [float(l) for l in open(sys.argv[1]) if l.strip()]
n = len(diffs)
method = "exact" if n <= 25 else "approx"
res = sps.wilcoxon(diffs, method=method, correction=(method == "approx"), zero_method="wilcox")
print(json.dumps({"statistic": float(res.statistic), "p_value": float(res.pvalue), "method": method, "exact": method == "exact", "n": n}))
' "$vals")

  # Studentized CI; handle zero-variance (all diffs identical) degenerate case as in original.
  local variance ci_out
  variance=$(python3 -c "
import numpy as np
vals = [float(l) for l in open('$vals') if l.strip()]
print(np.var(vals, ddof=1) if len(vals) > 1 else 0.0)
")
  if python3 -c "import sys; sys.exit(0 if float('$variance') == 0.0 else 1)"; then
    ci_out=$(jq -n --argjson m "$mean_diff" --argjson n "$N" --argjson a "$ALPHA" \
      '{ci_lower:$m, ci_upper:$m, point:$m, n_resamples:$n, method:"studentized", alpha:$a, degenerate:true}')
  else
    ci_out=$(SEED="${SEED_OPT:-}" stats_bootstrap::studentized "$vals" "$N" "$ALPHA")
  fi

  jq -n --argjson n_paired "$n_paired" --argjson mean_diff "$mean_diff" \
        --argjson wilcoxon "$wilcoxon" --argjson ci "$ci_out" \
        --argjson ma "$missing_a" --argjson mb "$missing_b" \
        '{n_paired:$n_paired, mean_diff:$mean_diff, wilcoxon:$wilcoxon, ci:$ci, missing_from_a:$ma, missing_from_b:$mb}'
}

# _fired_block: per-arm gamma-band sweep via gamma_bands::compute (F3).
# Per L0 B11 line 102: do NOT emit mean_diff or point CI on fired subset.
_fired_block() {
  local paired_jsonl="$1"
  local n_fired; n_fired=$(jq -c 'select(.fired == 1)' "$paired_jsonl" | wc -l | tr -d ' ')
  if [ "$n_fired" -lt 1 ]; then
    jq -n '{n_paired:0, gamma_bounded:null, mean_diff:null, ci:null, caveat:"compaction-fired subset has zero paired observations"}'
    return
  fi
  # Mean per arm on the fired subset (raw cost - gamma_bands operates on raw cost ratio space).
  local cost_a cost_b
  cost_a=$(jq -r 'select(.fired == 1) | .value_a' "$paired_jsonl" | awk '{s+=$1;n++} END{if(n) print s/n; else print 0}')
  cost_b=$(jq -r 'select(.fired == 1) | .value_b' "$paired_jsonl" | awk '{s+=$1;n++} END{if(n) print s/n; else print 0}')
  local per_arm_cost_json
  per_arm_cost_json=$(jq -n --argjson a "$cost_a" --argjson b "$cost_b" '{arm_a:$a, arm_b:$b}')
  # Consume gamma_bands::compute from lib/gamma-bands.sh (already sourced above).
  local gamma_bounded
  gamma_bounded=$(gamma_bands::compute "$per_arm_cost_json" "$GAMMA_MIN" "$GAMMA_MAX")

  # Wilcoxon p still meaningful on the fired subset (sign test on log-diff has DM-OPE-independent meaning).
  local wilcoxon
  wilcoxon=$(jq -r 'select(.fired == 1) | ((.value_a | log) - (.value_b | log))' "$paired_jsonl" | python3 -c '
import sys, json
import numpy as np
from scipy import stats as sps
diffs = [float(l) for l in sys.stdin if l.strip()]
if not diffs:
    print(json.dumps({"statistic": None, "p_value": None, "n": 0})); sys.exit(0)
method = "exact" if len(diffs) <= 25 else "approx"
res = sps.wilcoxon(diffs, method=method, correction=(method=="approx"), zero_method="wilcox")
print(json.dumps({"statistic": float(res.statistic), "p_value": float(res.pvalue), "method": method, "n": len(diffs)}))
')

  # Caveat: L0 B11 prohibitive statement + canonical wording from gamma_bands::caveat.
  # The prohibition "do not point-estimate the contrast on the compaction-fired subset"
  # is the key B11 gate; cc12_caveat adds methodological attribution.
  local cc12_text=''
  if declare -f gamma_bands::caveat >/dev/null 2>&1; then
    cc12_text=$(gamma_bands::caveat 2>/dev/null || true)
    cc12_text=$(jq -r '.' <<<"$cc12_text" 2>/dev/null || echo "$cc12_text")
  fi
  local caveat_text
  if [ -n "$cc12_text" ]; then
    caveat_text="Per L0 B11: do not point-estimate the contrast on the compaction-fired subset. Per-arm Gamma bands (gamma_bands::compute) reported under gamma_bounded. ${cc12_text}"
  else
    caveat_text='Per L0 B11 (Bennett-Kallus-Oprescu transition-kernel MSM): do not point-estimate the contrast on the compaction-fired subset. Per-arm sharp Gamma bands reported under gamma_bounded.'
  fi

  jq -n --argjson n_fired "$n_fired" --argjson gb "$gamma_bounded" \
        --argjson w "$wilcoxon" --arg cav "$caveat_text" \
        '{n_paired:$n_fired, mean_diff:null, ci:null, wilcoxon:$w, gamma_bounded:$gb, caveat:$cav}'
}

# Assemble tri-block JSON output.
# ONLY_A = keys in A not in B → missing_from_b (B lacks them); ONLY_B = keys in B not in A → missing_from_a.
CLEAN_OUT='null'; FIRED_OUT='null'
case "$SUBSET" in
  clean) CLEAN_OUT=$(_clean_block "$CLEAN_VALS" "$ONLY_B" "$ONLY_A") ;;
  fired) FIRED_OUT=$(_fired_block "$PAIRED_JSONL") ;;
  both)  CLEAN_OUT=$(_clean_block "$CLEAN_VALS" "$ONLY_B" "$ONLY_A"); FIRED_OUT=$(_fired_block "$PAIRED_JSONL") ;;
esac

jq -n --argjson clean "$CLEAN_OUT" --argjson fired "$FIRED_OUT" \
      --arg subset "$SUBSET" --argjson log_diffs "$LOG_DIFFS" \
      '{subset:$subset, log_diffs:($log_diffs == 1), clean:$clean, fired:$fired}'
