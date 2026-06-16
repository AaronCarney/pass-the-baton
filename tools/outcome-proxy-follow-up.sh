#!/usr/bin/env bash
# tools/outcome-proxy-follow-up.sh - secondary proxy: per-project session+turn density.
# Numeric-only output (L0 D1 / L1 §E16 line 206).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.claude/hooks/lib/outcome-proxies.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/eventlog.sh"

TRANSCRIPTS_DIR=""
JSON_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --transcripts-dir) TRANSCRIPTS_DIR="$2"; shift 2;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) echo 'Usage: outcome-proxy-follow-up.sh [--transcripts-dir PATH] [--json]'; exit 0;;
    *) echo "outcome-proxy-follow-up: unknown flag '$1'" >&2; exit 1;;
  esac
done

# F8: transcripts-dir resolution order: flag > $BATON_CORPUS_DIR > $HOME/.claude/projects.
if [ -z "$TRANSCRIPTS_DIR" ]; then
  if [ -n "${BATON_CORPUS_DIR:-}" ]; then
    TRANSCRIPTS_DIR="$BATON_CORPUS_DIR"
  else
    TRANSCRIPTS_DIR="${HOME:-/root}/.claude/projects"
  fi
fi
if [ ! -d "$TRANSCRIPTS_DIR" ]; then
  echo "outcome-proxy-follow-up: transcripts directory not found ('$TRANSCRIPTS_DIR'); turn counts will be 0" >&2
fi

log_path="${BATON_EVENT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl}"
[ -f "$log_path" ] || exit 0

# Group start events by slug → distinct terminal_ids + workstream.
pairs=$(eventlog::stream "$log_path" | jq -cs '
  map(select(.event == "project_boundary" and .data.kind == "start"))
  | group_by(.data.slug)
  | map({
      slug: .[0].data.slug,
      workstream: (.[0].data.workstream // "main"),
      terminals: ([.[].data.terminal_id] | unique)
    })
')

echo "$pairs" | jq -c '.[]' | while IFS= read -r row; do
  slug=$(echo "$row" | jq -r '.slug')
  ws=$(echo "$row" | jq -r '.workstream')
  n_terminals=$(echo "$row" | jq -r '.terminals | length')
  # F9: n_sessions = unique session-id transcript filenames under <transcripts-dir>/<workstream>/*.jsonl.
  n_sessions=0
  total_turns=0
  if [ -d "$TRANSCRIPTS_DIR/$ws" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      n_sessions=$((n_sessions+1))
      n=$(grep -c '"type":"assistant"' "$f" 2>/dev/null || echo 0)
      total_turns=$((total_turns + n))
    done < <(find "$TRANSCRIPTS_DIR/$ws" -maxdepth 1 -name '*.jsonl' -type f)
  fi
  mean_turns=0
  [ "$n_sessions" -gt 0 ] && mean_turns=$(awk -v t="$total_turns" -v s="$n_sessions" 'BEGIN{printf "%.2f", t/s}')
  payload=$(jq -cn \
    --arg slug "$slug" \
    --argjson n_sessions "$n_sessions" \
    --argjson n_terminals "$n_terminals" \
    --arg mean_turns_per_session "$mean_turns" \
    --argjson total_turns "$total_turns" \
    '{slug: $slug, n_sessions: $n_sessions, n_terminals: $n_terminals,
      mean_turns_per_session: ($mean_turns_per_session | tonumber), total_turns: $total_turns}')
  if [ "$JSON_ONLY" = "1" ]; then
    echo "$payload" | jq -c '. + {subkind: "follow_up"}'
  else
    outcome_proxies::emit_event follow_up "$payload" || true
  fi
done
exit 0
