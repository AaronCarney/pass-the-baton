#!/bin/bash
# resume.sh - canonical workstream rebind/recovery CLI.
# Lists active + last-30-days-archived workstreams; rebinds this terminal
# (via term_hash) to a chosen workstream, restoring from archive if needed.
# Generic; no project-specific references.
#
# Usage: bash tools/resume.sh [--list | <ws-id>]
set -u

PROJECT_DIR="${BATON_PROJECT_DIR:-$PWD}"
# Resolve the library relative to THIS script so the CLI works for a plugin
# install (script lives under ${CLAUDE_PLUGIN_ROOT}) and a clone alike; fall back
# to the consumer-project layout for legacy by-reference installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOKS_LIB="$SCRIPT_DIR/../.claude/hooks/lib/workstream-lib.sh"
[ -f "$HOOKS_LIB" ] || HOOKS_LIB="$PROJECT_DIR/.claude/hooks/lib/workstream-lib.sh"
if [ ! -f "$HOOKS_LIB" ]; then
  echo "ERROR: workstream-lib.sh not found (looked in $SCRIPT_DIR/../.claude/hooks/lib and $PROJECT_DIR/.claude/hooks/lib)" >&2
  exit 1
fi
source "$HOOKS_LIB"

TRACKING="$(checkpoint_dir "$PROJECT_DIR")"
ARCHIVE_BASE="$(archive_dir)"

ARG="${1:---list}"
if [ "$ARG" != "--list" ] && ! [[ "$ARG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: invalid arg '$ARG' - expected --list or a workstream id ([a-zA-Z0-9_-]+)" >&2
  exit 1
fi

list_active() {
  local f ws dn phase ts now=$(date -u +%s)
  local lines=()
  for f in "$TRACKING/workstreams"/*.json; do
    [ -f "$f" ] || continue
    ws=$(jq -r '.workstream // empty' "$f" 2>/dev/null)
    [ -z "$ws" ] && continue
    dn=$(jq -r '.display_name // .workstream' "$f" 2>/dev/null)
    phase=$(jq -r '.phase // "unknown"' "$f" 2>/dev/null)
    ts=$(jq -r '.updated_at // empty' "$f" 2>/dev/null)
    local epoch; epoch=$(parse_iso8601 "$ts")
    lines+=("${epoch}|${ws}|${dn}|${phase}|${ts}")
  done
  # Sort by epoch desc
  printf '%s\n' "${lines[@]}" | sort -t'|' -k1,1nr
}

list_archived() {
  local thirty_days_ago=$(($(date -u +%s) - 30*86400))
  local f ws dn pd ts
  local lines=()
  for f in "$ARCHIVE_BASE/checkpoint-state"/*/workstreams/*.json; do
    [ -f "$f" ] || continue
    pd=$(jq -r '.project_dir // empty' "$f" 2>/dev/null)
    [ "$pd" = "$PROJECT_DIR" ] || continue   # NF3 cross-project isolation
    ws=$(jq -r '.workstream // empty' "$f" 2>/dev/null)
    [ -z "$ws" ] && continue
    dn=$(jq -r '.display_name // .workstream' "$f" 2>/dev/null)
    ts=$(jq -r '.updated_at // empty' "$f" 2>/dev/null)
    local epoch; epoch=$(parse_iso8601 "$ts")
    [ "$epoch" -lt "$thirty_days_ago" ] && continue
    lines+=("${epoch}|${ws}|${dn}|${ts}")
  done
  printf '%s\n' "${lines[@]}" | sort -t'|' -k1,1nr
}

do_list() {
  local active_lines archived_lines
  active_lines=$(list_active)
  archived_lines=$(list_archived)

  if [ -z "$active_lines" ] && [ -z "$archived_lines" ]; then
    echo "No active or recently-archived workstreams. Start a new session or see docs/install.md."
    return 0
  fi

  if [ -n "$active_lines" ]; then
    echo "Active workstreams:"
    local n=0
    while IFS='|' read -r epoch ws dn phase ts; do
      [ -z "$ws" ] && continue
      n=$((n+1))
      printf "  %d. %s (workstream: %s, phase: %s, updated: %s)\n" "$n" "$dn" "$ws" "$phase" "$ts"
    done <<< "$active_lines"
  fi

  if [ -n "$archived_lines" ]; then
    echo "Archived workstreams (last 30 days):"
    local n=0
    while IFS='|' read -r epoch ws dn ts; do
      [ -z "$ws" ] && continue
      n=$((n+1))
      printf "  A%d. %s (workstream: %s, archived: %s) (archived)\n" "$n" "$dn" "$ws" "$ts"
    done <<< "$archived_lines"
  fi
}

do_rebind() {
  local ws="$1"
  local ws_file="$TRACKING/workstreams/${ws}.json"

  if [ ! -f "$ws_file" ]; then
    # Try archive restore - self-locate the sibling tool so a plugin install
    # (script under ${CLAUDE_PLUGIN_ROOT}) works; fall back to consumer layout.
    local restore_tool="$SCRIPT_DIR/restore-workstream.sh"
    [ -f "$restore_tool" ] || restore_tool="$PROJECT_DIR/tools/restore-workstream.sh"
    if ! bash "$restore_tool" "$ws" >/dev/null 2>&1; then
      echo "ERROR: workstream '$ws' not found in active or archived state" >&2
      return 2
    fi
    [ -f "$ws_file" ] || { echo "ERROR: restore failed to materialize $ws_file" >&2; return 3; }
  fi

  # Bump updated_at on workstream record (per Cluster F: /resume must bump).
  # F6: hold flock across jq+mv to coordinate with cron's prune flock.
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp; tmp=$(mktemp -p "$(dirname "$ws_file")")
  exec 9>"${ws_file}.lock"
  flock 9
  jq --arg ts "$now" '.updated_at = $ts' "$ws_file" > "$tmp" && mv "$tmp" "$ws_file"
  local _rc=$?
  flock -u 9
  exec 9>&-
  if [ "$_rc" -ne 0 ]; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: failed to update workstream record $ws_file" >&2
    return 3
  fi

  # Rewrite terminals/<term_hash>.json (shared primitive, see workstream-lib.sh)
  rebind_terminal "$TRACKING" "$ws"

  echo "Bound this terminal to $ws." >&2
  return 0
}

if [ "$ARG" = "--list" ]; then
  do_list
  exit 0
fi

do_rebind "$ARG"
exit $?
