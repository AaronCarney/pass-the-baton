#!/usr/bin/env bash
# tools/recommend.sh - recommend a checkpoint method based on cost, time, and outcome data.
# Orchestrates cost-sweep-corpus.sh + time-to-complete-corpus.sh + outcome-proxy-rollup.sh,
# builds per-method arm jsonl files, then calls recommend::aggregate + recommend::format.
set -uo pipefail
export LC_ALL=C

# Capture repo root BEFORE any sourced lib can clobber _SD.
_REC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Source libs: recommend-aggregate.sh already sources release-dates + recommend-*.sh.
# replay-harness.sh requires: stats-bootstrap, tokens, cost-models, cost-model-*.sh, transcript.sh
# shellcheck source=/dev/null
source "$_REC_REPO/lib/stats-bootstrap.sh"
# stats-bootstrap.sh may set _SD to lib/; re-anchor repo root.
_REC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/tokens.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/cost-models.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/transcript.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/cost-model-compact.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/cost-model-automemory.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/cost-model-clear-only.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/cost-model-none.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/replay-harness.sh"
# recommend-aggregate.sh also sources release-dates + recommend-*.sh.
# shellcheck source=/dev/null
source "$_REC_REPO/lib/recommend-aggregate.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/recommend-format.sh"
# shellcheck source=/dev/null
source "$_REC_REPO/lib/time-to-complete.sh"

# c-016: sourcing-smoke - declare -f all 6 contracted library functions in current shell
{ declare -f replay_harness::compact_total >/dev/null \
  && declare -f replay_harness::automemory_total >/dev/null \
  && declare -f replay_harness::clear_only_total >/dev/null \
  && declare -f replay_harness::none_total >/dev/null \
  && declare -f time_to_complete::find_sessions >/dev/null \
  && declare -f time_to_complete::infer_method >/dev/null; } || {
  printf 'recommend.sh: required library function missing - check lib/replay-harness.sh and lib/time-to-complete.sh\n' >&2
  exit 1
}

# ── Defaults ────────────────────────────────────────────────────────────────────
MODE='human'
CORPUS="${HOME}/.claude/projects"
SINCE=''
EVENTS="${BATON_EVENT_LOG:-${XDG_STATE_HOME:-${HOME}/.local/state}/baton/hook-events.jsonl}"
STRICT_RECENT='false'
COST_JSON=''

usage() {
  cat <<EOF
Usage: recommend.sh [OPTIONS]

Recommends a baton method (compact/clear-only/automemory/none)
based on cost, time-to-complete, and outcome-proxy data.

Options:
  --human            Output human-readable report (default)
  --json             Output raw JSON
  --corpus DIR       Transcript corpus directory (default: ~/.claude/projects)
  --since DATE       Window start date (YYYY-MM-DD); overrides event-log minimum
  --log PATH         Events JSONL file (default: BATON_EVENT_LOG or state dir)
  --strict-recent    Omit sessions that predate the model's release date
  --cost-json PATH   Use pre-built cost JSON instead of running cost-sweep-corpus.sh
                     (test affordance / power-user; bypasses corpus cost sweep)
  -h, --help         Show this help and exit

Note: --corpus, --log, and --cost-json are primarily test-affordance / power-user flags.
EOF
}

# ── Flag parser ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --human)       MODE='human';   shift ;;
    --json)        MODE='json';    shift ;;
    --corpus)      CORPUS="$2";   shift 2 ;;
    --since)       SINCE="$2";    shift 2 ;;
    --log)         EVENTS="$2";   shift 2 ;;
    --strict-recent) STRICT_RECENT='true'; shift ;;
    --cost-json)   COST_JSON="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      printf 'recommend.sh: unknown flag: %s\n' "$1" >&2
      printf 'Run with --help for usage.\n' >&2
      exit 1
      ;;
  esac
done

# ── Temp dir ─────────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/arms"

# c-017: honor CC_NOW
today_iso="${CC_NOW:-$(date -u +%Y-%m-%d)}"

# ── (a) Cost JSON ─────────────────────────────────────────────────────────────────
if [[ -n "$COST_JSON" ]]; then
  cp "$COST_JSON" "$TMP/cost.json"
else
  if bash "$_REC_REPO/tools/cost-sweep-corpus.sh" --corpus "$CORPUS" --json > "$TMP/cost.json" 2>/dev/null; then
    : # success
  else
    printf '{}' > "$TMP/cost.json"
  fi
fi

# ── (b) Time JSON ─────────────────────────────────────────────────────────────────
if bash "$_REC_REPO/tools/time-to-complete-corpus.sh" --events "$EVENTS" --rigor workshop --json > "$TMP/time.json" 2>/dev/null; then
  :
else
  printf '{}' > "$TMP/time.json"
fi

# ── (c) Outcome JSON ─────────────────────────────────────────────────────────────
if bash "$_REC_REPO/tools/outcome-proxy-rollup.sh" --log "$EVENTS" --json > "$TMP/outcome.json" 2>/dev/null; then
  :
else
  printf '{}' > "$TMP/outcome.json"
fi

# ── (d) Window FROM/TO ────────────────────────────────────────────────────────────
FROM="$(recommend_window::from "$EVENTS" "$SINCE")"
TO="$today_iso"

# ── (e) COST arm-jsonl build ──────────────────────────────────────────────────────
# Get model from cost.json (used for all replay_harness calls)
COST_MODEL="$(jq -r '.model // "claude-sonnet-4-6"' "$TMP/cost.json" 2>/dev/null || printf 'claude-sonnet-4-6')"

# c-018: initialize REPLAY_HARNESS_NONZERO_ARMS BEFORE the loop (covers zero-iteration case)
REPLAY_HARNESS_NONZERO_ARMS=0

while IFS= read -r tpath; do
  [[ -z "$tpath" ]] && continue
  [[ ! -f "$tpath" ]] && continue
  sid="$(basename "$tpath" .jsonl)"

  for arm in compact clear_only automemory none; do
    case "$arm" in
      compact)    cost_val="$(replay_harness::compact_total "$COST_MODEL" "$tpath" 2>/dev/null)" || cost_val='0' ;;
      clear_only) cost_val="$(replay_harness::clear_only_total "$COST_MODEL" "$tpath" 2>/dev/null)" || cost_val='0' ;;
      automemory) cost_val="$(replay_harness::automemory_total "$COST_MODEL" "$tpath" 2>/dev/null)" || cost_val='0' ;;
      none)       cost_val="$(replay_harness::none_total "$COST_MODEL" "$tpath" 2>/dev/null)" || cost_val='0' ;;
    esac
    # Normalize empty to 0
    [[ -z "$cost_val" ]] && cost_val='0'
    printf '{"slug":"%s","value":%s}\n' "$sid" "$cost_val" >> "$TMP/arms/arm-${arm}.jsonl"
    # c-018: count arm/transcript pairs whose cost > 0
    if awk "BEGIN{exit !($cost_val > 0)}"; then
      REPLAY_HARNESS_NONZERO_ARMS=$(( REPLAY_HARNESS_NONZERO_ARMS + 1 ))
    fi
  done
done < <(jq -r '.transcripts[].path' "$TMP/cost.json" 2>/dev/null || true)

# c-018: export sentinel
export REPLAY_HARNESS_NONZERO_ARMS

# ── (f0) Degenerate-recovery gate (c-018) ────────────────────────────────────────
if [[ "$REPLAY_HARNESS_NONZERO_ARMS" == '0' ]]; then
  # Skip paired-deltas: omit --arms-dir; aggregator sets cost_producer_degenerate=true
  recommend::aggregate \
    --cost "$TMP/cost.json" \
    --time "$TMP/time.json" \
    --outcome "$TMP/outcome.json" \
    --events "$EVENTS" \
    --since "$SINCE" \
    --to "$TO" \
    --strict-recent "$STRICT_RECENT" \
  | recommend::format "$MODE"
  exit 0
fi

# ── (f)+(g) Aggregate ────────────────────────────────────────────────────────────
recommend::aggregate \
  --cost "$TMP/cost.json" \
  --time "$TMP/time.json" \
  --outcome "$TMP/outcome.json" \
  --events "$EVENTS" \
  --arms-dir "$TMP/arms" \
  --since "$SINCE" \
  --to "$TO" \
  --strict-recent "$STRICT_RECENT" \
| recommend::format "$MODE"
