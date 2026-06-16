#!/usr/bin/env bash
# tools/time-to-complete-corpus.sh - per-method wall-clock aggregator with CC12 subset awareness.
# Reads project_boundary events from a JSONL event log; emits per-method TTC stats.
# Optional paired-difference block when --paired.
set -uo pipefail
export LC_ALL=C

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$_SD/lib/stats-bootstrap.sh"
# stats-bootstrap.sh resets _SD to lib/ - restore to repo root.
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$_SD/lib/transcript.sh"
# shellcheck source=/dev/null
source "$_SD/lib/subset-stratify.sh"
# shellcheck source=/dev/null
source "$_SD/lib/time-to-complete.sh"

EVENTS=''; CORPUS="${HOME}/.claude/projects"; METHOD_FILTER=''; STATUS_FILTER=''
WS_INCLUDE=(); WS_EXCLUDE=(); DATE_FROM=''; DATE_TO=''; SUBSET='both'
METHOD_MAP=''; PAIRED=0; OUT_MODE='json'
STRATIFY_BY=''; RIGOR='preprint'; CI_METHOD="${CI_METHOD:-studentized-log}"

usage() {
  cat <<EOF
Usage: time-to-complete-corpus.sh --events <jsonl> [--corpus <dir>]
       [--method <m>] [--status <s>] [--workspace <glob>] [--workspace-exclude <glob>]
       [--date-from <ISO>] [--date-to <ISO>] [--subset clean|fired|both]
       [--method-map <json>] [--paired] [--json | --human]
       [--stratify-by KEY[,KEY...]] [--rigor LEVEL] [--ci-method METHOD]

  --stratify-by KEY[,KEY...]  Partition sessions by KEY before aggregating.
                              Allowed KEYs: workspace, session_shape, model, date_bucket.
                              Multiple keys joined with comma (nested partitioning).
                              NOTE: .strata output for time-to-complete is planned
                              for E16 (Outcome-quality proxy infrastructure); the
                              flag is accepted in E15 for forward-compat but does
                              not currently emit .strata. cost-sweep-corpus.sh
                              emits .strata correctly in E15.

  --rigor LEVEL               Statistical rigor level (default: preprint).
                              preprint - point estimates only (baseline, no CI).
                              workshop  - studentized-on-log CI on per-method aggregates (default).
                              mlsys     - workshop CI + paired comparison of top-2 methods.
                              Auto-enables --stratify-by workspace when omitted with workshop/mlsys.

  --ci-method METHOD          Bootstrap CI method for workshop/mlsys rigor (default: studentized-log).
                              studentized-log - studentized bootstrap on log-transformed values (L1 §E15).
                              bca             - BCa bootstrap (sensitivity check, L0 §A5 line 69).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --events)            EVENTS="$2"; shift 2 ;;
    --corpus)            CORPUS="$2"; shift 2 ;;
    --method)            METHOD_FILTER="$2"; shift 2 ;;
    --status)            STATUS_FILTER="$2"; shift 2 ;;
    --workspace)         WS_INCLUDE+=("$2"); shift 2 ;;
    --workspace-exclude) WS_EXCLUDE+=("$2"); shift 2 ;;
    --date-from)         DATE_FROM="$2"; shift 2 ;;
    --date-to)           DATE_TO="$2"; shift 2 ;;
    --subset)            SUBSET="$2"; shift 2 ;;
    --method-map)        METHOD_MAP="$2"; shift 2 ;;
    --paired)            PAIRED=1; shift ;;
    --json)              OUT_MODE='json'; shift ;;
    --human)             OUT_MODE='human'; shift ;;
    --stratify-by)       STRATIFY_BY="$2"; shift 2 ;;
    --rigor)             RIGOR="$2"; shift 2 ;;
    --ci-method)         CI_METHOD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$EVENTS" ]; then
  printf 'time-to-complete-corpus: --events is required\n' >&2
  usage >&2
  exit 1
fi
if [ ! -f "$EVENTS" ]; then
  printf 'time-to-complete-corpus: events file not found: %s\n' "$EVENTS" >&2
  exit 2
fi
case "$SUBSET" in
  clean|fired|both) ;;
  *) printf 'time-to-complete-corpus: --subset must be clean|fired|both (got: %s)\n' "$SUBSET" >&2; exit 1 ;;
esac
case "$METHOD_FILTER" in
  ''|none|auto-memory|clear-only|compact) ;;
  *) printf 'time-to-complete-corpus: --method must be none|auto-memory|clear-only|compact (got: %s)\n' "$METHOD_FILTER" >&2; exit 1 ;;
esac

# Validate --stratify-by keys.
if [ -n "$STRATIFY_BY" ]; then
  IFS=',' read -ra _KEYS <<< "$STRATIFY_BY"
  for k in "${_KEYS[@]}"; do
    case "$k" in
      workspace|session_shape|model|date_bucket) ;;
      *) printf 'time-to-complete-corpus: invalid --stratify-by key %q (allowed: workspace, session_shape, model, date_bucket)\n' "$k" >&2; exit 1;;
    esac
  done
fi
case "$RIGOR" in
  preprint|workshop|mlsys) ;;
  *) printf 'time-to-complete-corpus: invalid --rigor %q (allowed: preprint, workshop, mlsys)\n' "$RIGOR" >&2; exit 1;;
esac
# workshop/mlsys auto-enables a default stratification if user didn't specify one.
if [ "$RIGOR" != 'preprint' ] && [ -z "$STRATIFY_BY" ]; then
  STRATIFY_BY='workspace'
fi

# Source-order guard.
for fn in time_to_complete::compute_per_project time_to_complete::find_sessions \
           time_to_complete::infer_method time_to_complete::aggregate_per_method \
           time_to_complete::paired_delta subset_stratify::compaction_fired; do
  declare -f "$fn" >/dev/null || {
    printf 'time-to-complete-corpus: required function not defined: %s\n' "$fn" >&2
    exit 2
  }
done

# ---- Per-project records ----
WORKDIR=$(mktemp -d)
PER_PROJECT=$(mktemp); trap 'rm -f "$PER_PROJECT" 2>/dev/null; rm -rf "$WORKDIR" 2>/dev/null; rm -f "${_CLEANUP_TMP:-}"' EXIT
time_to_complete::compute_per_project "$EVENTS" > "$PER_PROJECT"

# ---- Method-map override ----
METHOD_MAP_JSON='{}'
if [ -n "$METHOD_MAP" ]; then
  [ ! -f "$METHOD_MAP" ] && {
    printf 'time-to-complete-corpus: method-map file not found: %s\n' "$METHOD_MAP" >&2
    exit 2
  }
  METHOD_MAP_JSON=$(cat "$METHOD_MAP")
fi

# ---- Per-session annotation ----
ANNOTATED="$WORKDIR/annotated"

# E15: producer-side per-method per-session sidecar for downstream CI / paired-compare consumers.
for _m in compact auto-memory clear-only none; do
  : > "$WORKDIR/vals_${_m}.jsonl"
done
while IFS= read -r rec; do
  [ -z "$rec" ] && continue
  slug=$(printf '%s' "$rec" | jq -r '.slug')
  ws=$(printf '%s' "$rec" | jq -r '.workstream')
  start_ts=$(printf '%s' "$rec" | jq -r '.start_ts')
  status=$(printf '%s' "$rec" | jq -r '.status')

  # Project-level filters.
  [ -n "$DATE_FROM" ] && [ "$start_ts" \< "$DATE_FROM" ] && continue
  [ -n "$DATE_TO" ]   && [ "$start_ts" \> "$DATE_TO" ]   && continue
  [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ] && continue
  if [ "${#WS_INCLUDE[@]}" -gt 0 ]; then
    matched=0
    for g in "${WS_INCLUDE[@]}"; do
      # shellcheck disable=SC2053
      [[ "$ws" == $g ]] && { matched=1; break; }
    done
    [ "$matched" = '0' ] && continue
  fi
  for g in "${WS_EXCLUDE[@]}"; do
    # shellcheck disable=SC2053
    [[ "$ws" == $g ]] && continue 2
  done

  # Method-map override (project-wide).
  method_override=$(printf '%s' "$METHOD_MAP_JSON" | jq -r --arg s "$slug" '.[$s] // ""')

  # Find sessions overlapping this project's time window.
  sessions=$(time_to_complete::find_sessions "$rec" "$CORPUS")
  if [ -z "$sessions" ]; then
    method="${method_override:-none}"
    [ -n "$METHOD_FILTER" ] && [ "$method" != "$METHOD_FILTER" ] && continue
    printf '%s' "$rec" | jq -c \
      --arg m "$method" --arg sub 'clean' --arg sid 'NO_SESSION' \
      '. + {session_id: $sid, method_inferred: $m, subset: $sub}' >> "$ANNOTATED"
    continue
  fi

  while IFS= read -r sess; do
    [ -z "$sess" ] && continue
    if [ -n "$method_override" ]; then
      method="$method_override"
    else
      method="$(time_to_complete::infer_method "$sess")"
    fi
    [ -n "$METHOD_FILTER" ] && [ "$method" != "$METHOD_FILTER" ] && continue

    if [ "$(subset_stratify::compaction_fired "$sess" 2>/dev/null)" = '1' ]; then
      sub='fired'
    else
      sub='clean'
    fi

    sid=$(basename "$sess" .jsonl)
    printf '%s' "$rec" | jq -c \
      --arg m "$method" --arg sub "$sub" --arg sid "$sid" \
      '. + {session_id: $sid, method_inferred: $m, subset: $sub}' >> "$ANNOTATED"

    # E15: emit per-session per-method value sidecar for downstream CI / paired-compare.
    # Field is .wall_clock_seconds (set by lib/time-to-complete.sh:41 compute_per_project),
    # not .seconds - the original T8 spec used the wrong field name and the empty fallback
    # silently produced empty sidecar files, suppressing .strata + .ci emission.
    _val_seconds=$(printf '%s' "$rec" | jq -r '.wall_clock_seconds // empty')
    if [ -n "$_val_seconds" ]; then
      printf '{"slug":"%s","method":"%s","value":%s}\n' "$sid" "$method" "$_val_seconds" >> "$WORKDIR/vals_${method}.jsonl"
    fi
  done <<< "$sessions"
done < "$PER_PROJECT"

# ---- Aggregate + emit ----
PER_METHOD=$(time_to_complete::aggregate_per_method "$ANNOTATED" --subset "$SUBSET")

PAIRED_BLOCK='null'
if [ "$PAIRED" = '1' ]; then
  PAIRED_BLOCK=$(time_to_complete::paired_delta "$ANNOTATED")
fi

# ---- E15: workshop/mlsys CI attachment ----
_attach_ci() {
  # Attach bootstrap CI to each method in PER_METHOD using vals_${method}.jsonl sidecars.
  # Default: studentized-on-log (log-safe for strictly positive wall-clock seconds).
  # BCa sensitivity check available via --ci-method bca (L0 §A5 line 69).
  local pm="$1"
  for _m in compact auto-memory clear-only none; do
    local vf="$WORKDIR/vals_${_m}.jsonl"
    [ -f "$vf" ] || continue
    local n_vals
    n_vals=$(wc -l < "$vf" 2>/dev/null || echo 0)
    [ "$n_vals" -lt 1 ] && continue
    local ci_json
    local _method="${CI_METHOD:-studentized-log}"
    case "$_method" in
      studentized-log)
        ci_json=$(jq -r '.value' "$vf" | stats_bootstrap::studentized_log - 2>/dev/null) || continue ;;
      bca)
        ci_json=$(jq -r '.value' "$vf" | stats_bootstrap::bca - 2>/dev/null) || continue ;;
      *)
        printf 'time-to-complete-corpus: unknown --ci-method %q (allowed: studentized-log, bca)\n' "$_method" >&2; continue ;;
    esac
    [ -z "$ci_json" ] && continue
    pm=$(printf '%s' "$pm" | jq -c --arg m "$_m" --argjson ci "$ci_json" \
      'if .[$m] then .[$m].ci = $ci else . end')
  done
  printf '%s' "$pm"
}

PAIRED_COMPARE='null'
if [ "$RIGOR" = 'workshop' ] || [ "$RIGOR" = 'mlsys' ]; then
  PER_METHOD=$(_attach_ci "$PER_METHOD")
fi

if [ "$RIGOR" = 'mlsys' ]; then
  # TODO(E16): default-invoke tools/hierarchical-model.py for mlsys rigor when n_paired >= 30
  # Find top-2 methods by n (non-zero val files).
  _methods_with_vals=()
  for _m in compact auto-memory clear-only none; do
    local_vf="$WORKDIR/vals_${_m}.jsonl"
    [ -f "$local_vf" ] && [ "$(wc -l < "$local_vf" 2>/dev/null || echo 0)" -gt 0 ] && _methods_with_vals+=("$_m")
  done
  if [ "${#_methods_with_vals[@]}" -ge 2 ]; then
    _m_a="${_methods_with_vals[0]}"
    _m_b="${_methods_with_vals[1]}"
    PAIRED_COMPARE=$(bash "$_SD/tools/paired-compare.sh" \
      --arm-a "$WORKDIR/vals_${_m_a}.jsonl" \
      --arm-b "$WORKDIR/vals_${_m_b}.jsonl" \
      --key slug --json 2>/dev/null) || PAIRED_COMPARE='null'
  fi
fi

if [ "$OUT_MODE" = 'json' ]; then
  jq -n \
    --argjson pm "$PER_METHOD" \
    --argjson pd "$PAIRED_BLOCK" \
    --argjson pc "$PAIRED_COMPARE" \
    --arg method "${METHOD_FILTER:-null}" \
    --arg status "${STATUS_FILTER:-null}" \
    --arg ws_inc "$(IFS=,; printf '%s' "${WS_INCLUDE[*]:-}")" \
    --arg subset "$SUBSET" \
    --arg rigor "$RIGOR" \
    --arg df "${DATE_FROM:-null}" --arg dt "${DATE_TO:-null}" \
    '{
       schema_version: 1,
       tool: "time-to-complete-corpus",
       filters: {
         method:    (if $method == "null" then null else $method end),
         status:    (if $status == "null" then null else $status end),
         workspace: (if $ws_inc == "" then null else $ws_inc end),
         subset:    $subset,
         date_from: (if $df == "null" then null else $df end),
         date_to:   (if $dt == "null" then null else $dt end)
       },
       per_method: $pm
     }
     + (if $pd == null then {} else {paired_delta: $pd} end)
     + (if $pc == null then {} else {paired_compare: $pc} end)'
else
  printf 'Time-to-complete corpus aggregate\n'
  printf '=================================\n'
  printf 'Subset filter: %s\n' "$SUBSET"
  [ -n "$METHOD_FILTER" ] && printf 'Method filter: %s\n' "$METHOD_FILTER"
  printf '\n'
  printf '%s\n' "$PER_METHOD" | jq -r \
    'to_entries | .[] | "  \(.key): n=\(.value.n) mean=\(.value.mean_seconds)s median=\(.value.median_seconds)s"'
  if [ "$PAIRED" = '1' ] && [ "$PAIRED_BLOCK" != 'null' ]; then
    printf '\nPaired-difference (slugs spanning ≥2 methods):\n'
    printf '%s\n' "$PAIRED_BLOCK" | jq -r \
      '.[] | "  \(.slug): \(.pairs | map("\(.method_a) vs \(.method_b): Δ=\(.delta_seconds)s ratio=\(.ratio)") | join(", "))"'
  fi
fi
