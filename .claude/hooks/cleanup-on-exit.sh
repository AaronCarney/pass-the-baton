#!/bin/bash
# SessionEnd hook. Archives every per-session tracking file produced by
# this terminal (including those from prior /clear cycles via the registry)
# to cold storage, then removes all live-session /tmp keys for those
# session IDs. Terminal-scoped state in .tracking/terminals/<hash>.json
# is preserved so the next launch on this terminal can re-bind.
set -u

input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.cwd')
[ -z "$SESSION_ID" ] && exit 0
[ -z "$CWD" ] && exit 0
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/workstream-lib.sh" 2>/dev/null || true

# Prefer BATON_ARCHIVE_DIR; fall back to OLORIN_ARCHIVE_DIR with a deprecation warning.
if [ -n "${OLORIN_ARCHIVE_DIR:-}" ] && [ -z "${BATON_ARCHIVE_DIR:-}" ]; then
  echo "[checkpoint] WARN: OLORIN_ARCHIVE_DIR is deprecated; set BATON_ARCHIVE_DIR instead" >&2
  BATON_ARCHIVE_DIR="$OLORIN_ARCHIVE_DIR"
fi
ARCHIVE_BASE="$(archive_dir)"
YEAR_MONTH=$(date +%Y-%m)
TRACKING_DIR="$(checkpoint_dir "$PROJECT_DIR")"

# Create archive destination
DEST_DIR="$ARCHIVE_BASE/sessions/$YEAR_MONTH"
mkdir -p "$DEST_DIR"

# 1. Move this session's tracking file to cold storage via its /tmp pointer
T_POINTER="/tmp/claude-session-tracking-${SESSION_ID}"
if [ -f "$T_POINTER" ]; then
  T_FILE=$(cat "$T_POINTER")
  if [ -f "$T_FILE" ]; then
    mv "$T_FILE" "$DEST_DIR/$(basename "$T_FILE")"
  fi
  [ -f "${T_FILE}.lock" ] && rm -f "${T_FILE}.lock"
fi

# A checkpoint was demanded but never delivered: PENDING is still set and DONE
# was never latched. Every silent-loss path in the lifecycle converges here, so
# record it before the sweep below erases the evidence. MUST stay above the
# section-2 removals - they delete the DONE flag this check reads.
_CO_PENDING="/tmp/baton-pending-${SESSION_ID}"
if [ -f "$_CO_PENDING" ] && [ ! -f "/tmp/baton-done-${SESSION_ID}" ]; then
  _CO_PCT=$(cat "$_CO_PENDING" 2>/dev/null || echo "")
  if declare -F log_event >/dev/null 2>&1; then
    log_event "$PROJECT_DIR" checkpoint abandoned-pending \
      "session_id=$SESSION_ID" "pct=$_CO_PCT" "cwd=$CWD" 2>/dev/null || true
  fi
fi

# 2. Clean live /tmp state files for this session ID
rm -f "/tmp/claude-context-pct-${SESSION_ID}"
rm -f "/tmp/claude-context-triggered-${SESSION_ID}"
rm -f "/tmp/baton-done-${SESSION_ID}"
rm -f "/tmp/baton-done-${SESSION_ID}.fired"
# E6 relaunch driver's fire-once marker. NOTE: the RELAUNCH REQUEST marker
# ($BATON_RELAUNCH_REQ, terminal-keyed) must NOT be swept here - the supervisor
# reads it after this hook runs, and its survival is the whole mechanism.
rm -f "/tmp/baton-done-${SESSION_ID}.relaunch-fired"
rm -f "/tmp/baton-pending-${SESSION_ID}"
rm -f "/tmp/baton-archive-${SESSION_ID}"
rm -f "/tmp/baton-health-${SESSION_ID}"
rm -f "/tmp/baton-warned-${SESSION_ID}"
rm -f "/tmp/baton-nag-${SESSION_ID}"
rm -f "$T_POINTER"

# 3. Truncate debug log if > 100KB (shared across all terminals)
DEBUG_LOG="/tmp/claude-ws-debug.log"
if [ -f "$DEBUG_LOG" ]; then
  SIZE=$(stat -c %s "$DEBUG_LOG" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt "${_BATON_DEBUG_LOG_MAX_BYTES:-102400}" ]; then
    tail -50 "$DEBUG_LOG" > "${DEBUG_LOG}.tmp" && mv "${DEBUG_LOG}.tmp" "$DEBUG_LOG"
  fi
fi

# Stamp .closed_at on THIS terminal's binding so the roster drops it immediately
# (the binding file itself is preserved for relaunch re-bind; session-start clears
# .closed_at when the terminal re-binds).
TH=$(term_hash)
TERM_FILE="$TRACKING_DIR/terminals/${TH}.json"
if [ -f "$TERM_FILE" ]; then
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.closed_at = $ts' "$TERM_FILE" | atomic_write "$TERM_FILE"
fi

exit 0
