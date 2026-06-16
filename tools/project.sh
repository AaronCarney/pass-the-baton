#!/usr/bin/env bash
# tools/project.sh - CLI for marking project boundaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/projects.sh"

usage() {
  cat <<'EOF'
Usage: tools/project.sh <subcommand> [args]

Subcommands:
  mark-start <slug> [--method LABEL] [--description TEXT]
  mark-end <slug> --status success|abandoned|paused [--note TEXT]
  list [--active|--all]
  show <slug>

Environment:
  CLAUDE_WORKSTREAM    workstream id (defaults to 'unassociated' if unset)
  CLAUDE_TERMINAL_ID   terminal id (defaults to hostname-PPID)

Exit codes:
  0 success
  1 argument error (missing slug, unknown flag, bad enum)
  2 state error (no such project, double-start, mismatched end)
EOF
}

resolve_workstream() { echo "${CLAUDE_WORKSTREAM:-unassociated}"; }
resolve_terminal() { echo "${CLAUDE_TERMINAL_ID:-$(hostname)-${PPID:-0}}"; }

cmd_mark_start() {
  local slug='' description='' method=''
  while (( $# > 0 )); do
    case "$1" in
      --description) description="$2"; shift 2 ;;
      --method) method="$2"; shift 2 ;;
      --*) echo "unknown flag: $1" >&2; return 1 ;;
      *) [[ -z "$slug" ]] && slug="$1" || { echo "unexpected positional: $1" >&2; return 1; }; shift ;;
    esac
  done
  if [[ -z "$slug" ]]; then echo "mark-start: slug required" >&2; return 1; fi
  local ws; ws="$(resolve_workstream)"
  local term; term="$(resolve_terminal)"
  projects::mark_start_state "$slug" "$ws" "$description" "$term" "$method"
  projects::emit_event start "$slug" "$ws" "$term" '' "$description"
  echo "project: started $slug (workstream=$ws, method=${method:-none})"
}

cmd_mark_end() {
  local slug='' status='' note=''
  while (( $# > 0 )); do
    case "$1" in
      --status) status="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      --*) echo "unknown flag: $1" >&2; return 1 ;;
      *) [[ -z "$slug" ]] && slug="$1" || { echo "unexpected positional: $1" >&2; return 1; }; shift ;;
    esac
  done
  if [[ -z "$slug" ]]; then echo "mark-end: slug required" >&2; return 1; fi
  if [[ -z "$status" ]]; then echo "mark-end: --status required (success|abandoned|paused)" >&2; return 1; fi
  projects::mark_end_state "$slug" "$status" "$note"
  local ws; ws="$(jq -r .workstream "$(projects::state_dir)/${slug}.json")"
  local term; term="$(resolve_terminal)"
  projects::emit_event end "$slug" "$ws" "$term" "$status" "$note"
  echo "project: ended $slug (status=$status)"
}

cmd_list() {
  local mode='active'
  case "${1:-}" in
    --active|'') mode='active' ;;
    --all) mode='all' ;;
    *) echo "list: flag must be --active or --all" >&2; return 1 ;;
  esac
  projects::list "$mode"
}

cmd_show() {
  local slug="${1:-}"
  if [[ -z "$slug" ]]; then echo "show: slug required" >&2; return 1; fi
  projects::show "$slug"
}

subcmd="${1:-}"; shift || true
case "$subcmd" in
  --help|-h|'') usage; exit 0 ;;
  mark-start) cmd_mark_start "$@" ;;
  mark-end) cmd_mark_end "$@" ;;
  list) cmd_list "$@" ;;
  show) cmd_show "$@" ;;
  *) echo "unknown subcommand: $subcmd" >&2; usage >&2; exit 1 ;;
esac
