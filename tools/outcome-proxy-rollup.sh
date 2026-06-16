#!/usr/bin/env bash
# tools/outcome-proxy-rollup.sh - per-method outcome-quality aggregates.
# CC12 subset awareness: headline = clean subset only; decomposition = both subsets.
# CC15 ranking: retry-density factors into ranking iff retry-intent-status.json says load_bearing.
# F1: method derived via .baton/projects.json sibling join (NOT an invented event field).
# F2: subset derived via lib/subset-stratify.sh::compaction_fired on per-session transcripts.
# F3: fired-subset decomposition is L1-mandated and emitted inline (NOT deferred).
# F7: per-subkind aggregation - no cross-subkind mean conflation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.claude/hooks/lib/outcome-proxies.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/transcript.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/subset-stratify.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/eventlog.sh"

LOG="${BATON_EVENT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl}"
STATUS_FILE="$REPO_ROOT/.baton/retry-intent-status.json"
PROJECTS_STATE="${BATON_PROJECTS_STATE:-$REPO_ROOT/.baton/projects.json}"
TRANSCRIPTS_DIR="${BATON_CORPUS_DIR:-$HOME/.claude/projects}"
JSON_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="$2"; shift 2;;
    --status-file) STATUS_FILE="$2"; shift 2;;
    --projects-state) PROJECTS_STATE="$2"; shift 2;;
    --transcripts-dir) TRANSCRIPTS_DIR="$2"; shift 2;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) echo 'Usage: outcome-proxy-rollup.sh [--log PATH] [--status-file PATH] [--projects-state PATH] [--transcripts-dir PATH] [--json]'; exit 0;;
    *) echo "unknown flag '$1'" >&2; exit 1;;
  esac
done
[ -f "$LOG" ] || { echo '{"error":"no event log"}'; exit 0; }

retry_status="triage"
[ -f "$STATUS_FILE" ] && retry_status=$(jq -r '.status // "triage"' "$STATUS_FILE" 2>/dev/null || echo triage)

# F1: build slug -> method map by sibling join against projects state file.
# Schema: $PROJECTS_STATE is {"<slug>": {"method": "baton|compact|automemory|..."}, ...}.
slug_to_method='{}'
if [ -f "$PROJECTS_STATE" ]; then
  slug_to_method=$(jq -c 'with_entries(.value = (.value.method // "unknown"))' "$PROJECTS_STATE" 2>/dev/null || echo '{}')
fi

# Build session_id -> {slug, workstream, terminal_id, method, subset} map by walking project_boundary events.
# subset is determined per-session by running subset_stratify::compaction_fired on the matching transcript.
declare -A SESSION_META
while IFS= read -r row; do
  [ -z "$row" ] && continue
  sid=$(printf '%s' "$row" | jq -r '.session_id // empty')
  slug=$(printf '%s' "$row" | jq -r '.slug // empty')
  ws=$(printf '%s' "$row" | jq -r '.workstream // "main"')
  tid=$(printf '%s' "$row" | jq -r '.terminal_id // empty')
  [ -z "$sid" ] && sid="$tid"
  [ -z "$sid" ] && continue
  method=$(printf '%s' "$slug_to_method" | jq -r --arg s "$slug" '.[$s] // "unknown"')
  if [ "$method" = "unknown" ]; then
    echo "outcome-proxy-rollup: no method tag for slug=$slug; using 'unknown'" >&2
  fi
  transcript_path="$TRANSCRIPTS_DIR/$ws/$sid.jsonl"
  subset="clean"
  if [ -f "$transcript_path" ]; then
    fired=$(subset_stratify::compaction_fired "$transcript_path" 2>/dev/null || echo 0)
    [ "$fired" = "1" ] && subset="fired"
  fi
  SESSION_META[$sid]="$method|$subset|$tid"
done < <(eventlog::stream "$LOG" | jq -c 'select(.event == "project_boundary") | {session_id: (.data.session_id // .data.terminal_id), slug: .data.slug, workstream: (.data.workstream // "main"), terminal_id: .data.terminal_id}')

# Build a JSON join sidecar that jq can index: {<session_id>: {method, subset}}.
meta_json='{}'
for sid in "${!SESSION_META[@]}"; do
  IFS='|' read -r m s _ <<< "${SESSION_META[$sid]}"
  meta_json=$(printf '%s' "$meta_json" | jq -c --arg sid "$sid" --arg m "$m" --arg s "$s" '. + {($sid): {method: $m, subset: $s}}')
done

# G1 (closeout): events with session_id route via $meta (session→slug→method); events with slug-only (T4a/T4b) route via $slug_to_method direct.
# Aggregate outcome_proxy events grouped by (method, subset, subkind), pre-filtered per subkind (F7).
result=$(eventlog::stream "$LOG" | jq -cs --argjson meta "$meta_json" --argjson slug_to_method "$slug_to_method" --arg retry_status "$retry_status" '
  def session_key(e): (e.data.session_id // e.data.terminal_id // null);
  def slug_key(e): (e.data.slug // null);
  def method_for(e):
    if session_key(e) != null and session_key(e) != "" and ($meta[session_key(e)].method // "") != "" then
      $meta[session_key(e)].method
    elif slug_key(e) != null and slug_key(e) != "" then
      ($slug_to_method[slug_key(e)] // "unknown")
    else
      "unknown"
    end;
  def subset_for(e):
    if session_key(e) != null and session_key(e) != "" and ($meta[session_key(e)].subset // "") != "" then
      $meta[session_key(e)].subset
    elif slug_key(e) != null and slug_key(e) != "" then
      "aggregate"
    else
      "clean"
    end;
  def agg_block(rows; subkind):
    if subkind == "code_execution" then
      {n: (rows | length), success_rate: ((rows | map(select(.data.success)) | length) / (rows | length))}
    elif subkind == "retry" then
      {n: (rows | length), mean: ((rows | map(.data.similarity) | add) / (rows | length))}
    elif subkind == "follow_up" then
      {n: (rows | length), mean: ((rows | map(.data.mean_turns_per_session) | add) / (rows | length))}
    elif subkind == "commit_survival" then
      {n: (rows | length), mean: ((rows | map(.data.survival_fraction) | add) / (rows | length))}
    else
      {n: (rows | length)}
    end;
  [.[] | select(.event == "outcome_proxy")]
  | map(. + {
      _method: method_for(.),
      _subset: subset_for(.),
      _subkind: .data.subkind
    })
  | (group_by(.["_method"]) | map({
      method: .[0]["_method"],
      headline: (
        [.[] | select(.["_subset"] == "clean" or .["_subset"] == "aggregate")]
        | group_by(.["_subkind"])
        | map({(.[0]["_subkind"]): agg_block(.; .[0]["_subkind"])})
        | add // {}
      ),
      decomposition: (
        group_by(.["_subset"])
        | map({(.[0]["_subset"]): (
            group_by(.["_subkind"])
            | map({(.[0]["_subkind"]): agg_block(.; .[0]["_subkind"])})
            | add // {}
          )})
        | add // {}
      )
    })) as $by_method
  | {
      retry_status: $retry_status,
      ranking_includes_retry: ($retry_status == "load_bearing"),
      headline: ($by_method | map(select(.headline != {}) | {(.method): .headline}) | add // {}),
      decomposition: ($by_method | map({(.method): .decomposition}) | add // {})
    }
')

if [ "$JSON_ONLY" = "1" ]; then
  printf '%s\n' "$result"
else
  echo "# Outcome-quality roll-up"
  echo ""
  echo "Retry-density status: $retry_status"
  echo "Retry factored into ranking: $(printf '%s' "$result" | jq -r '.ranking_includes_retry')"
  echo ""
  echo "## Headline (clean subset; CC12 cross-method ranking)"
  printf '%s' "$result" | jq -r '.headline | to_entries[] | "\n### method=\(.key)\n" + (.value | to_entries | map("- \(.key): \(.value | tojson)") | join("\n"))'
  echo ""
  echo "## Decomposition (NOT for cross-method ranking)"
  printf '%s' "$result" | jq -r '.decomposition | to_entries[] | "\n### method=\(.key)\n" + (.value | to_entries | map("  - subset=\(.key): " + (.value | to_entries | map("\(.key)=\(.value | tojson)") | join(", "))) | join("\n"))'
  echo ""
  # TODO(E16-followup): token-entropy / EAS supplementary surface
  # TODO(E16-followup): LLM-as-judge supplementary surface with bias mitigations
fi
exit 0
