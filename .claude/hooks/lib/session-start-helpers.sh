#!/bin/bash
# Helpers for .claude/hooks/session-start.sh. Lifted into a separate library so
# tests can source the function without triggering session-start.sh's top-level
# `input=$(cat)` and exit-guards.

_SSH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SSH_REPO_ROOT="$(cd "$_SSH_SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
source "$_SSH_REPO_ROOT/lib/projects.sh"

# Returns a one-line nudge if the workstream has no active project marker AND
# has been idle for >= 7 days (per started_at). Empty string otherwise.
session_start::maybe_project_prompt() {
  local ws="$1"
  [[ -n "$ws" ]] || return 0
  local active; active="$(projects::active_for_workstream "$ws")"
  if [[ -n "$active" ]]; then return 0; fi
  local idle; idle="$(projects::idle_days "$ws")"
  if (( idle < 7 )); then return 0; fi
  echo 'No active project marker. Run tools/project.sh mark-start <slug> to start tracking per-project economics.'
}
