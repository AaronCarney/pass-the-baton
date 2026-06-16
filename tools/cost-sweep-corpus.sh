#!/usr/bin/env bash
# tools/cost-sweep-corpus.sh - corpus-wide threshold-sweep aggregator (basic rigor).
# Reads only `usage` numerics from transcripts (CC8 privacy).
# No network. Math via the cost-compare-model oracle; prefix + summary-tokens
# derivation shared with tools/cost-compare.sh via lib/cost-compare-model.sh.
set -uo pipefail
export LC_ALL=C

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
# Note: source stats-bootstrap.sh via explicit path to avoid it clobbering $_SD (it sets its own).
source "$_SD/lib/stats-bootstrap.sh"; _SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$_SD/lib/cost-models.sh"
# shellcheck source=/dev/null
source "$_SD/lib/tokens.sh"
# shellcheck source=/dev/null
source "$_SD/lib/transcript.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-compare-model.sh"
# shellcheck source=/dev/null
source "$_SD/lib/corpus.sh"
# shellcheck source=/dev/null
source "$_SD/lib/sweep-aggregate.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-model-compact.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-model-automemory.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-model-clear-only.sh"
# shellcheck source=/dev/null
source "$_SD/lib/cost-model-none.sh"
# shellcheck source=/dev/null
source "$_SD/lib/replay-harness.sh"
# shellcheck source=/dev/null
source "$_SD/lib/subset-stratify.sh"
# shellcheck source=/dev/null
source "$_SD/lib/aggregator-v2.sh"
# shellcheck source=/dev/null
source "$_SD/lib/audit-metadata.sh"
# shellcheck source=/dev/null
source "$_SD/lib/gamma-bands.sh"

DISCLAIMER="Token counts are an estimate computed from content size and Anthropic's published per-model tokenizer behavior. Actual API billing uses Anthropic's authoritative count, which may differ by up to ~5% on prose and up to ~35% on code or structured text for Opus 4.7. For a billing-grade figure, use \`bash tools/cost.sh --verify --corpus DIR\`."

METHOD="baton-threshold"
SCHEMA_VERSION=3

THRESHOLDS=(10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 never)

usage() {
  cat <<EOF
Usage: cost-sweep-corpus.sh [--corpus DIR] [--workspace-include GLOB]...
                            [--workspace-exclude GLOB]... [--include-subagents]
                            [--model ID] [--summary-model ID] [--summary-tokens N]
                            [--limit N] [--json] [--self-check]
                            [--stratify-by KEY[,KEY...]] [--rigor LEVEL]
                            [-h | --help]

Runs the threshold counterfactual sweep across a corpus of Claude Code
transcripts and reports per-threshold summary stats. Default corpus root:
~/.claude/projects/. Default behavior excludes the subagents/ workspace.

  --stratify-by KEY[,KEY...]  Partition sessions by KEY before aggregating.
                              Allowed KEYs: workspace, session_shape, model, date_bucket.
                              Multiple keys joined with comma (nested partitioning).
                              Adds .strata object to JSON output.

  --rigor LEVEL               Statistical rigor level (default: preprint).
                              preprint - point estimates only (baseline, no CI).
                              workshop  - BCA bootstrap CI on per-method aggregates.
                              mlsys     - workshop CI + paired comparison of top-2 methods.
                              Auto-enables --stratify-by workspace when omitted with workshop/mlsys.
EOF
}

CORPUS="${HOME}/.claude/projects"
MODEL="${BATON_COST_MODEL:-claude-sonnet-4-6}"
SUMMARY_MODEL="${BATON_SUMMARY_MODEL:-}"
SUMMARY_TOKENS="${BATON_SUMMARY_TOKENS:-}"
AUTOMEMORY_TOKENS="${BATON_AUTOMEMORY_TOKENS:-5000}"
LIMIT=0
JSON=0
SELF_CHECK=0
INC_SUB=0
INC_GLOBS=()
EXC_GLOBS=()
STRATIFY_BY=''
RIGOR='preprint'
CI_METHOD="${CI_METHOD:-studentized-log}"
# WITH_HIERARCHICAL: --with-hierarchical flag is accepted in E15 for forward-compat
# but is a parse-only no-op; wiring deferred to E16 (Outcome-quality proxy infrastructure).
# The reshape from per-session cost data to {workspace, project, session, y} JSONL
# requires the project_boundary event surface scoped to E16.

while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2;;
    --workspace-include) INC_GLOBS+=("$2"); shift 2;;
    --workspace-exclude) EXC_GLOBS+=("$2"); shift 2;;
    --include-subagents) INC_SUB=1; shift;;
    --model) MODEL="$2"; shift 2;;
    --summary-model) SUMMARY_MODEL="$2"; shift 2;;
    --summary-tokens) SUMMARY_TOKENS="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    --json) JSON=1; shift;;
    --self-check) SELF_CHECK=1; shift;;
    --stratify-by) STRATIFY_BY="$2"; shift 2;;
    --rigor) RIGOR="$2"; shift 2;;
    --ci-method) CI_METHOD="$2"; shift 2;;
    # TODO(E16): wire --with-hierarchical to tools/hierarchical-model.py invocation + .hierarchical JSON attach
    --with-hierarchical) shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# Validate --stratify-by keys.
if [ -n "$STRATIFY_BY" ]; then
  IFS=',' read -ra _KEYS <<< "$STRATIFY_BY"
  for k in "${_KEYS[@]}"; do
    case "$k" in
      workspace|session_shape|model|date_bucket) ;;
      *) echo "cost-sweep-corpus: invalid --stratify-by key '$k' (allowed: workspace, session_shape, model, date_bucket)" >&2; exit 1;;
    esac
  done
fi
case "$RIGOR" in
  preprint|workshop|mlsys) ;;
  *) echo "cost-sweep-corpus: invalid --rigor '$RIGOR' (allowed: preprint, workshop, mlsys)" >&2; exit 1;;
esac
# workshop/mlsys auto-enables a default stratification if user didn't specify one.
if [ "$RIGOR" != 'preprint' ] && [ -z "$STRATIFY_BY" ]; then
  STRATIFY_BY='workspace'
fi

# Resolve summary-tokens via shared derivation (parity with tools/cost-compare.sh).
if [ -z "$SUMMARY_TOKENS" ]; then
  IFS='|' read -r SUMMARY_TOKENS _IGNORED_NOTE < <(ccmp::derive_summary_tokens_default)
fi
case "$SUMMARY_TOKENS" in
  ''|*[!0-9]*) echo "cost-sweep-corpus.sh: --summary-tokens must be a non-negative integer: $SUMMARY_TOKENS" >&2; exit 2;;
esac
: "${SUMMARY_MODEL:=$MODEL}"

# Validate models (parity with tools/cost-compare.sh).
if ! cost_models::cost_of_turn "$MODEL" 0 0 0 1 1 >/dev/null 2>&1; then
  echo "cost-sweep-corpus.sh: unknown model: $MODEL" >&2; exit 2
fi
if ! cost_models::cost_of_turn "$SUMMARY_MODEL" 0 0 0 1 1 >/dev/null 2>&1; then
  echo "cost-sweep-corpus.sh: unknown summary model: $SUMMARY_MODEL" >&2; exit 2
fi

# Cross-model summary-input rate via shared lifted helper (parity with tools/cost-compare.sh:128-132 - byte-identical).
sg_in_rate=$(ccmp::derive_sg_in_rate "$SUMMARY_MODEL" "$MODEL" "$SUMMARY_TOKENS")

# Summary-gen scalar (USD per /clear) via ccmp::summary_gen_cost.
SGEN=$(ccmp::summary_gen_cost "$SUMMARY_MODEL" "$SUMMARY_TOKENS")

if [ "$SELF_CHECK" -eq 1 ]; then
  if [ ! -f "$0" ]; then
    echo "self-check: must be invoked via 'bash tools/cost-sweep-corpus.sh --self-check' (got \$0=$0)" >&2
    exit 2
  fi
  TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
  mkdir -p "$TD/proj/ws"
  : > "$TD/proj/ws/check-1.jsonl"
  for i in 1 2 3 4 5; do
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":5000}}}\n' >> "$TD/proj/ws/check-1.jsonl"
  done
  # Both sides go through the shared lifted helpers - identity is exact.
  agg=$(BATON_PROGRESS_DIR="$TD/no-prog" BATON_ARCHIVE_DIR="$TD/no-arch" bash "$0" --corpus "$TD/proj" --json 2>/dev/null | jq -r '.aggregates["28"].median')
  direct=$(BATON_PROGRESS_DIR="$TD/no-prog" BATON_ARCHIVE_DIR="$TD/no-arch" bash "$_SD/tools/cost-compare.sh" --transcript "$TD/proj/ws/check-1.jsonl" --json 2>/dev/null | jq -r '.thresholds["28"]')
  if [ -z "$agg" ] || [ -z "$direct" ]; then echo "self-check: missing values agg=$agg direct=$direct" >&2; exit 1; fi
  ok=$(LC_ALL=C awk -v a="$agg" -v b="$direct" 'BEGIN{ d=a-b; if (d<0) d=-d; print (d<0.000005)?"yes":"no" }')
  if [ "$ok" != "yes" ]; then echo "self-check: identity broke: agg=$agg vs direct=$direct" >&2; exit 1; fi
  # Cross-model arm: exercise ccmp::derive_sg_in_rate by running both tools with a
  # different --summary-model than --model. Byte-equal T=28 medians prove the lifted
  # rate calc flows through both sides without inline divergence (iter-2 A3 guard).
  agg_x=$(BATON_PROGRESS_DIR="$TD/no-prog" BATON_ARCHIVE_DIR="$TD/no-arch" \
    bash "$0" --corpus "$TD/proj" --json --model claude-sonnet-4-6 --summary-model claude-opus-4-7 \
    2>/dev/null | jq -r '.aggregates["28"].median')
  direct_x=$(BATON_PROGRESS_DIR="$TD/no-prog" BATON_ARCHIVE_DIR="$TD/no-arch" \
    bash "$_SD/tools/cost-compare.sh" --transcript "$TD/proj/ws/check-1.jsonl" --json \
    --model claude-sonnet-4-6 --summary-model claude-opus-4-7 \
    2>/dev/null | jq -r '.thresholds["28"]')
  if [ -z "$agg_x" ] || [ -z "$direct_x" ]; then
    echo "self-check: cross-model values missing agg=$agg_x direct=$direct_x" >&2; exit 1
  fi
  if [ "$agg_x" != "$direct_x" ]; then
    echo "self-check: cross-model identity broke: agg=$agg_x vs direct=$direct_x" >&2; exit 1
  fi
  echo "self-check: identity holds (shared ccmp::derive_prefix + derive_summary_tokens_default + derive_sg_in_rate; same-model + cross-model arms)"
  exit 0
fi

LIST_ARGS=()
for g in "${INC_GLOBS[@]}"; do LIST_ARGS+=(--workspace-include "$g"); done
for g in "${EXC_GLOBS[@]}"; do LIST_ARGS+=(--workspace-exclude "$g"); done
[ "$INC_SUB" -eq 1 ] && LIST_ARGS+=(--include-subagents)
[ "$LIMIT" -gt 0 ] && LIST_ARGS+=(--limit "$LIMIT")

TRANSCRIPTS_TSV=$(corpus::list "$CORPUS" "${LIST_ARGS[@]}" || true)
if [ -z "$TRANSCRIPTS_TSV" ]; then
  N_TRANS=0
else
  N_TRANS=$(printf '%s\n' "$TRANSCRIPTS_TSV" | grep -c .)
fi
if [ "$N_TRANS" -eq 0 ]; then echo "no transcripts found under $CORPUS" >&2; exit 1; fi

WORKDIR=$(mktemp -d); trap 'rm -rf "$WORKDIR"' EXIT
: > "$WORKDIR/best_thresholds"
for t in "${THRESHOLDS[@]}"; do : > "$WORKDIR/t_$t"; done
PT_JSON="$WORKDIR/per_transcript.jsonl"
: > "$PT_JSON"

SW=$(printf '%s' "${THRESHOLDS[*]}")

declare -a TRANSCRIPT_PATHS=()
while IFS=$'\t' read -r path ws sid bytes turns; do
  TRANSCRIPT_PATHS+=("$path")
  [ -z "$path" ] && continue
  STREAM=$(transcript::turn_stream "$path" 2>/dev/null || true)
  [ -z "$STREAM" ] && continue
  PREFIX=$(printf '%s\n' "$STREAM" | ccmp::derive_prefix)
  PREFIX="${PREFIX:-0}"
  SWEEP=$(ccmp::threshold_sweep "$MODEL" "$PREFIX" "$STREAM" "$SW" "$SGEN" "$sg_in_rate")
  best_t=$(printf '%s\n' "$SWEEP" | LC_ALL=C sort -t$'\t' -k2 -g | head -1 | awk -F'\t' '{print $1}')
  if [[ "$best_t" =~ ^[0-9]+$ ]]; then printf '%s\n' "$best_t" >> "$WORKDIR/best_thresholds"; fi
  while IFS=$'\t' read -r t c; do printf '%s\n' "$c" >> "$WORKDIR/t_$t"; done <<< "$SWEEP"
  pt_obj=$(printf '%s\n' "$SWEEP" | jq -Rn --arg path "$path" --arg ws "$ws" --arg sid "$sid" --arg best "$best_t" '
    [inputs | split("\t") | {(.[0]): (.[1]|tonumber)}] | add as $pt
    | {path:$path, workspace:$ws, session_id:$sid, best_threshold:($best | (tonumber? // .)), per_threshold:$pt}')
  printf '%s\n' "$pt_obj" >> "$PT_JSON"
done <<< "$TRANSCRIPTS_TSV"

AGG_JSON="$WORKDIR/agg.json"
echo '{}' > "$AGG_JSON"
for t in "${THRESHOLDS[@]}"; do
  stats=$(sweep_agg::summary_stats < "$WORKDIR/t_$t")
  med=$(printf '%s' "$stats" | awk -F'\t' '{print $1}')
  mean=$(printf '%s' "$stats" | awk -F'\t' '{print $2}')
  p95=$(printf '%s' "$stats" | awk -F'\t' '{print $3}')
  iqr=$(printf '%s' "$stats" | awk -F'\t' '{print $4}')
  cnt=$(printf '%s' "$stats" | awk -F'\t' '{print $5}')
  AGG_JSON_TMP=$(jq --arg t "$t" --arg med "$med" --arg mean "$mean" --arg p95 "$p95" --arg iqr "$iqr" --arg cnt "$cnt" '
    .[$t] = {median: ($med|tonumber? // null), mean: ($mean|tonumber? // null), p95: ($p95|tonumber? // null), iqr: ($iqr|tonumber? // null), count: ($cnt|tonumber? // null)}' "$AGG_JSON")
  printf '%s\n' "$AGG_JSON_TMP" > "$AGG_JSON"
done

BT_MEDIAN=$(sweep_agg::quantile 0.50 < "$WORKDIR/best_thresholds")
BT_MODE=$(sweep_agg::mode < "$WORKDIR/best_thresholds")
[ "$BT_MEDIAN" = 'NaN' ] && BT_MEDIAN='null'
[ "$BT_MODE"   = 'NaN' ] && BT_MODE='null'

# === E13b CC12/CC6 v2 surface: per-arm-per-subset accumulation ===
PAPS_TMP="$WORKDIR/per_arm_per_subset.jsonl"
: > "$PAPS_TMP"

# Initialize 4-arm × 2-subset accumulators (USD + session counts).
declare -A USD COUNT
for arm in compact auto-memory clear-only none; do
  for subset in clean fired; do
    USD["$arm/$subset"]='0.000000'
    COUNT["$arm/$subset"]=0
  done
done

# E15: producer-side per-arm per-session sidecar for downstream CI / paired-compare consumers.
for arm in compact auto-memory clear-only none; do
  : > "$WORKDIR/paps_${arm}.jsonl"
done

N_CLEAN=0; N_FIRED=0
WARN_COUNT=0
for tpath in "${TRANSCRIPT_PATHS[@]}"; do
  [ -z "$tpath" ] && continue
  cf="$(subset_stratify::compaction_fired "$tpath" 2>/dev/null)" || cf=0
  if [ "$cf" = '1' ]; then subset='fired'; N_FIRED=$((N_FIRED+1)); else subset='clean'; N_CLEAN=$((N_CLEAN+1)); fi
  sid="$(basename "$tpath" .jsonl)"

  for arm_pair in 'compact:replay_harness::compact_total' \
                  'auto-memory:replay_harness::automemory_total' \
                  'clear-only:replay_harness::clear_only_total' \
                  'none:replay_harness::none_total'; do
    arm="${arm_pair%%:*}"
    fn="${arm_pair#*:}"
    rc_arm=0
    if [ "$arm" = 'auto-memory' ]; then
      arm_cost="$($fn "$MODEL" "$tpath" "$AUTOMEMORY_TOKENS" 2>/dev/null)" || rc_arm=$?
    else
      arm_cost="$($fn "$MODEL" "$tpath" 2>/dev/null)" || rc_arm=$?
    fi
    if [ "$rc_arm" -ne 0 ] || [ -z "${arm_cost:-}" ]; then
      printf 'WARN cost-sweep-corpus: arm %q on transcript %q fell back to 0.000000 (replay_harness rc=%s)\n' "$arm" "$tpath" "$rc_arm" >&2
      arm_cost='0.000000'
      WARN_COUNT=$((WARN_COUNT+1))
    fi
    printf '{"slug":"%s","usd":%s}\n' "$sid" "$arm_cost" >> "$WORKDIR/paps_${arm}.jsonl"
    key="$arm/$subset"
    USD["$key"]=$(LC_ALL=C awk -v a="${USD[$key]}" -v b="$arm_cost" 'BEGIN{ printf "%.6f", a + b }')
    COUNT["$key"]=$((COUNT["$key"] + 1))
  done
done

# Build the per_arm_per_subset JSON array via aggregator_v2 helper
PAPS_JSON='['
first=1
for arm in compact auto-memory clear-only none; do
  for subset in clean fired; do
    [ $first -eq 0 ] && PAPS_JSON+=','
    PAPS_JSON+="$(aggregator_v2::per_arm_per_subset_block "$arm" "$subset" "${USD[$arm/$subset]}" "${COUNT[$arm/$subset]}")"
    first=0
  done
done
PAPS_JSON+=']'

# Compute clean_share for subset_size_warning
TOTAL=$((N_CLEAN + N_FIRED))
if [ "$TOTAL" -gt 0 ]; then
  CLEAN_SHARE=$(LC_ALL=C awk -v c="$N_CLEAN" -v t="$TOTAL" 'BEGIN{ printf "%.4f", c / t }')
else
  CLEAN_SHARE='1.0000'  # no transcripts → no warning
fi
SUBSET_WARN="$(aggregator_v2::subset_size_warning "$CLEAN_SHARE")"
CC12_CAVEAT="$(aggregator_v2::cc12_caveat)"

# v3: audit_metadata block
AM_JSON="$(audit_metadata::read)"

# v3: gamma_bands block - fired subset only (L0 §B11)
FIRED_COSTS=$(printf '%s' "$PAPS_JSON" | jq -c '[.[] | select(.subset == "fired") | {key: .arm, value: (.usd_total | tonumber)}] | from_entries')
if [ "$(printf '%s' "$FIRED_COSTS" | jq -e 'to_entries | map(select(.value != null and .value != 0)) | length > 0')" = 'true' ]; then
  GB_FIRED=$(gamma_bands::compute "$FIRED_COSTS")
  GAMMA_BANDS_JSON=$(jq -n --argjson f "$GB_FIRED" '{fired: $f, clean: null}')
else
  GAMMA_BANDS_JSON='null'
fi

# === E15: Stratification + CI + paired-compare helpers ===

_session_stratum_key() {
  # $1 = session jsonl path; emits the stratum key per --stratify-by.
  # Multi-key uses '|' as the join char.
  local sess="$1" out=''
  IFS=',' read -ra _KEYS <<< "$STRATIFY_BY"
  for k in "${_KEYS[@]}"; do
    local val
    case "$k" in
      workspace) val="$(basename "$(dirname "$sess")")";;
      session_shape)
        local msg_count; msg_count=$(wc -l < "$sess")
        if [ "$msg_count" -le 50 ]; then val='small'
        elif [ "$msg_count" -le 200 ]; then val='medium'
        else val='large'
        fi
        ;;
      model)
        val=$(jq -r 'select(.type=="assistant") | .message.model // "unknown"' "$sess" 2>/dev/null | head -1)
        [ -z "$val" ] && val='unknown'
        ;;
      date_bucket)
        local first_ts; first_ts=$(jq -r '.ts // empty' "$sess" 2>/dev/null | head -1)
        val=$(date -u -d "$first_ts" +'%G-W%V' 2>/dev/null || echo 'unknown')
        ;;
    esac
    out="${out:+$out|}$val"
  done
  printf '%s' "$out"
}

_aggregate_session_list() {
  # Signature: _aggregate_session_list <stratum_key> <paps_dir>
  # Reads session paths (newline-delimited) from stdin.
  # Filters producer-side paps_${arm}.jsonl sidecars by slug membership.
  # Writes float-per-line vals to $paps_dir/vals_${stratum_key}_${arm}.jsonl.
  # Outputs {per_method:{<arm>:{n,median,mean}}} JSON to stdout.
  # PURE re-aggregator - no THRESHOLDS/MODEL/SW/SGEN references.
  local stratum_key="$1" paps_dir="$2"
  local _paths_in; _paths_in=$(cat)
  declare -a _paths_arr=()
  while IFS= read -r p; do [ -n "$p" ] && _paths_arr+=("$p"); done <<< "$_paths_in"
  local _slug_set=''
  if [ "${#_paths_arr[@]}" -gt 0 ]; then
    _slug_set=$(printf '%s\n' "${_paths_arr[@]}" | while IFS= read -r _p; do [ -n "$_p" ] && basename "$_p" .jsonl; done | LC_ALL=C sort -u)
  fi
  local _allowed_json='[]'
  if [ -n "$_slug_set" ]; then
    _allowed_json=$(printf '%s' "$_slug_set" | jq -R . | jq -s '.')
  fi
  local _agg='{}'
  for arm in compact auto-memory clear-only none; do
    local vals_path="$paps_dir/vals_${stratum_key}_${arm}.jsonl"; : > "$vals_path"
    if [ -s "$paps_dir/paps_${arm}.jsonl" ]; then
      jq -c --argjson allowed "$_allowed_json" \
        'select(.slug as $s | $allowed | index($s) != null)' "$paps_dir/paps_${arm}.jsonl" \
        | jq -r '.usd' > "$vals_path" 2>/dev/null || true
    fi
    local n median mean
    n=$(wc -l < "$vals_path" 2>/dev/null || echo 0)
    median=$(LC_ALL=C sort -g "$vals_path" 2>/dev/null | awk 'BEGIN{c=0} {a[c++]=$1} END{ if(c==0){print "null"} else if(c%2==1){print a[int(c/2)]} else {printf "%.6f\n", (a[c/2 - 1] + a[c/2]) / 2} }')
    mean=$(awk '{s+=$1;n++} END{if(n>0) printf "%.6f", s/n; else print "null"}' "$vals_path")
    _agg=$(jq -n --argjson o "$_agg" --arg arm "$arm" --arg n "$n" --arg med "$median" --arg mean "$mean" \
      '$o + {($arm): {n:($n|tonumber), median:($med|tonumber? // null), mean:($mean|tonumber? // null)}}')
  done
  jq -n --argjson per_method "$_agg" '{per_method:$per_method}'
}

_emit_per_stratum() {
  # Partition TRANSCRIPT_PATHS by _session_stratum_key, call _aggregate_session_list per partition.
  # Uses the already-filtered $TRANSCRIPT_PATHS array (preserves all corpus filters).
  declare -A by_strat
  for s in "${TRANSCRIPT_PATHS[@]}"; do
    [ -z "$s" ] && continue
    local key; key=$(_session_stratum_key "$s")
    by_strat["$key"]+="$s"$'\n'
  done
  local out='{}'
  for k in "${!by_strat[@]}"; do
    local paths="${by_strat[$k]}"
    local _paths_file; _paths_file=$(mktemp)
    printf '%s' "$paths" > "$_paths_file"
    local stratum_agg; stratum_agg=$(_aggregate_session_list "$k" "$WORKDIR" < "$_paths_file")
    rm -f "$_paths_file"
    out=$(jq -n --argjson o "$out" --arg k "$k" --argjson v "$stratum_agg" '$o + {($k): $v}')
  done
  printf '%s' "$out"
}

_attach_ci() {
  # Takes a JSON aggregate ($1) and a float-per-line vals file ($2).
  # Default: studentized-on-log CI (log-safe for strictly positive costs, L1 §E15).
  # BCa sensitivity check available via --ci-method bca (L0 §A5 line 69).
  local agg="$1" vals="$2"
  if [ "$RIGOR" = 'preprint' ]; then printf '%s' "$agg"; return; fi
  if [ ! -s "$vals" ]; then
    echo "workshop: no vals sidecar for method-key (file: $vals); CI skipped" >&2
    printf '%s' "$agg"
    return
  fi
  local ci
  case "${CI_METHOD:-studentized-log}" in
    studentized-log)
      ci=$("$_SD/lib/stats-bootstrap.sh" studentized --input "$vals" --n-resamples 10000 --alpha 0.05 --log ${SEED:+--seed "$SEED"})
      ;;
    bca)
      ci=$("$_SD/lib/stats-bootstrap.sh" bca --input "$vals" --n-resamples 10000 --alpha 0.05 ${SEED:+--seed "$SEED"})
      ;;
    *)
      echo "cost-sweep-corpus: unknown --ci-method '${CI_METHOD}' (allowed: studentized-log, bca)" >&2
      printf '%s' "$agg"; return
      ;;
  esac
  jq -n --argjson agg "$agg" --argjson ci "$ci" '$agg + {ci: $ci}'
}

_workshop_ci_pass() {
  # Attach BCA CI to per-method aggregates (top-level + per-stratum). No-op when RIGOR=preprint.
  [ "$RIGOR" = 'preprint' ] && { printf '%s' "$BASE_JSON"; return; }
  # Project paps_${arm}.jsonl {slug,usd} rows to float-per-line for _attach_ci.
  for arm in compact auto-memory clear-only none; do
    if [ -s "$WORKDIR/paps_${arm}.jsonl" ]; then
      jq -r '.usd' "$WORKDIR/paps_${arm}.jsonl" > "$WORKDIR/vals_${arm}.jsonl"
    else
      : > "$WORKDIR/vals_${arm}.jsonl"
    fi
  done
  local methods; methods=$(jq -r '.per_method | keys[]' <<< "$BASE_JSON" 2>/dev/null || true)
  local updated="$BASE_JSON"
  for m in $methods; do
    local cur; cur=$(jq -c --arg m "$m" '.per_method[$m]' <<< "$updated")
    local new; new=$(_attach_ci "$cur" "$WORKDIR/vals_${m}.jsonl")
    updated=$(jq -c --arg m "$m" --argjson new "$new" '.per_method[$m] = $new' <<< "$updated")
  done
  # Per-stratum CI walk.
  local stratum_keys; stratum_keys=$(jq -r '.strata // {} | keys[]' <<< "$updated" 2>/dev/null || true)
  for sk in $stratum_keys; do
    local sm; sm=$(jq -r --arg sk "$sk" '.strata[$sk].per_method // {} | keys[]' <<< "$updated" 2>/dev/null || true)
    for arm in $sm; do
      local cur_stratum; cur_stratum=$(jq -c --arg sk "$sk" --arg arm "$arm" '.strata[$sk].per_method[$arm]' <<< "$updated")
      local new_stratum; new_stratum=$(_attach_ci "$cur_stratum" "$WORKDIR/vals_${sk}_${arm}.jsonl")
      updated=$(jq -c --arg sk "$sk" --arg arm "$arm" --argjson new "$new_stratum" '.strata[$sk].per_method[$arm] = $new' <<< "$updated")
    done
  done
  printf '%s' "$updated"
}

_mlsys_paired_compare() {
  # Invoke paired-compare.sh on top-2 methods by n. No-op when RIGOR != mlsys.
  [ "$RIGOR" != 'mlsys' ] && { printf '%s' "$BASE_JSON"; return; }
  local top_2_methods; top_2_methods=$(jq -r '.per_method | to_entries | sort_by(.value.n) | reverse | .[0:2] | map(.key) | join(",")' <<< "$BASE_JSON" 2>/dev/null || true)
  local m1="${top_2_methods%,*}" m2="${top_2_methods#*,}"
  { [ -z "$m1" ] || [ -z "$m2" ] || [ "$m1" = "$m2" ]; } && { printf '%s' "$BASE_JSON"; return; }
  local arm_a arm_b; arm_a=$(mktemp); arm_b=$(mktemp)
  jq -c '{slug:.slug, value:.usd}' "$WORKDIR/paps_${m1}.jsonl" > "$arm_a" 2>/dev/null || true
  jq -c '{slug:.slug, value:.usd}' "$WORKDIR/paps_${m2}.jsonl" > "$arm_b" 2>/dev/null || true
  local pc; pc=$(SEED="${SEED:-}" bash "$_SD/tools/paired-compare.sh" --arm-a "$arm_a" --arm-b "$arm_b" \
    --n-resamples 5000 --alpha 0.05 2>/dev/null || echo '{}')
  rm -f "$arm_a" "$arm_b"
  jq -n --argjson base "$BASE_JSON" --argjson pc "$pc" '$base + {paired_compare: $pc}'
}

if [ "$JSON" -eq 1 ]; then
  TRANS_ARRAY=$(jq -s '.' "$PT_JSON")
  BASE_JSON=$(jq -n \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg method "$METHOD" \
    --arg model "$MODEL" \
    --arg disclaimer "$DISCLAIMER" \
    --argjson aggregates "$(cat "$AGG_JSON")" \
    --argjson transcripts "$TRANS_ARRAY" \
    --argjson best_median "$( [ "$BT_MEDIAN" = 'null' ] && echo null || echo "$BT_MEDIAN" )" \
    --argjson best_mode "$( [ "$BT_MODE" = 'null' ] && echo null || echo "$BT_MODE" )" \
    --argjson per_arm_per_subset "$PAPS_JSON" \
    --argjson subset_size_warning "$SUBSET_WARN" \
    --argjson cc12_caveat "$CC12_CAVEAT" \
    --argjson audit_metadata "$AM_JSON" \
    --argjson gamma_bands "$GAMMA_BANDS_JSON" \
    --argjson warn_count "$WARN_COUNT" \
    '{schema_version:$schema_version, method:$method, model:$model, transcripts:$transcripts, aggregates:$aggregates, typical_best:{median:$best_median, mode:$best_mode}, disclaimer:$disclaimer, per_arm_per_subset:$per_arm_per_subset, subset_size_warning:$subset_size_warning, cc12_caveat:$cc12_caveat, audit_metadata:$audit_metadata, gamma_bands:$gamma_bands, warn_count:$warn_count}')
  # Additive E15 keys - gated on flag presence (default path byte-identical to baseline).
  if [ -n "$STRATIFY_BY" ]; then
    STRATA_JSON=$(_emit_per_stratum)
    BASE_JSON=$(jq -n --argjson base "$BASE_JSON" --argjson strata "$STRATA_JSON" '$base + {strata: $strata}')
  fi
  BASE_JSON=$(_workshop_ci_pass)
  BASE_JSON=$(_mlsys_paired_compare)
  printf '%s\n' "$BASE_JSON"
  exit 0
fi

printf 'baton cost-sweep-corpus - method=%s model=%s\n' "$METHOD" "$MODEL"
printf 'corpus=%s    transcripts: %s\n' "$CORPUS" "$N_TRANS"
printf '%-10s %-12s %-12s %-12s %-12s %-8s\n' THRESHOLD MEDIAN MEAN P95 IQR COUNT
printf '────────────────────────────────────────────────────────────────────\n'
for t in "${THRESHOLDS[@]}"; do
  med=$(jq -r --arg t "$t" '.[$t].median // "-"' "$AGG_JSON")
  mean=$(jq -r --arg t "$t" '.[$t].mean // "-"' "$AGG_JSON")
  p95=$(jq -r --arg t "$t" '.[$t].p95 // "-"' "$AGG_JSON")
  iqr=$(jq -r --arg t "$t" '.[$t].iqr // "-"' "$AGG_JSON")
  cnt=$(jq -r --arg t "$t" '.[$t].count // "-"' "$AGG_JSON")
  printf '%-10s %-12s %-12s %-12s %-12s %-8s\n' "$t" "$med" "$mean" "$p95" "$iqr" "$cnt"
done
printf '────────────────────────────────────────────────────────────────────\n'
printf 'TYPICAL-BEST   median=%s   mode=%s\n' "$BT_MEDIAN" "$BT_MODE"
printf '\n%s\n' "$DISCLAIMER"
