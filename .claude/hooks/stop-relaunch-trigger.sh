#!/bin/bash
# Stop hook. Fires when claude finishes its final message for a turn. When a
# checkpoint was written during that turn AND the session runs under a baton-run
# supervisor, spawn the detached helper that terminates the session so a fresh one
# can relaunch (E6 driver option 2, BATON_AUTO_CONTINUE_MODE=relaunch).
#
# Ships to EVERY user: every precondition miss is a fast, silent no-op. Always
# exits 0 - a Stop hook exiting non-zero BLOCKS the stop and forces continuation.
set -u

: "${BATON_RELAUNCH_LOG:=${TMPDIR:-/tmp}/baton-relaunch.log}"
_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    >> "$BATON_RELAUNCH_LOG" 2>/dev/null || true
}

# Subagents never drive the supervisor (Stop is documented not to fire for them;
# guarded anyway, matching checkpoint-write-trigger.sh:77).
[ -n "${AGENT_SESSION_ID:-}" ] && exit 0

# No supervisor -> nothing could consume a relaunch. This is the plain-`claude`
# path: return before doing any work at all.
[ -n "${BATON_RELAUNCH_SUPERVISOR:-}" ] || exit 0
[ -n "${BATON_RELAUNCH_REQ:-}" ] || exit 0

input=$(cat)
SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

# Did a checkpoint happen this turn? Absent = ordinary turn = the common path.
DONE_FLAG="/tmp/baton-done-${SESSION_ID}"
[ -f "$DONE_FLAG" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F _cfg::auto_continue_mode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../../lib/config.sh" 2>/dev/null || true
fi
if ! declare -F _cfg::auto_continue_mode >/dev/null 2>&1; then
  # lib unreachable (plugin distribution): define a FAITHFUL inline fallback, copying
  # session-start.sh:32-43 - including its config.json layer. Env-only here would be a
  # silent behavior fork: a user who ran `baton-dashboard.sh set
  # auto_continue_mode=relaunch` has the mode in config.json and NOTHING in env, so an
  # env-only gate exits 0 forever while the dashboard reports `relaunch`. That is the
  # dashboard-vs-gate disagreement lib/config.sh:6-10 forbids, and the exact scenario
  # session-start.sh:25-26 says its inline fallback exists to prevent.
  if ! declare -F _cfg::get >/dev/null 2>&1; then
    _cfg::get() {
      local v; v="${!1:-}"
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
      local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json"
      local ck="${3:-$1}"
      if [ -f "$cfg" ]; then
        v="$(jq -r --arg k "$ck" '.[$k] // empty' "$cfg" 2>/dev/null || true)"
        if [ -n "$v" ] && [ "$v" != 'null' ]; then printf '%s' "$v"; return 0; fi
      fi
      printf '%s' "${2:-}"
    }
  fi
  _cfg::auto_continue_mode() {   # same precedence as lib/config.sh:65-73. Keep the two in step.
    # The 'off' literals here are UNAVOIDABLE: this branch runs only when
    # lib/config.sh is unreachable, so BATON_DEFAULT_AUTO_CONTINUE_MODE does not
    # exist to be read. The lib resolver - the one that CAN read it - still does.
    local m legacy_default=off
    [ "${BATON_AUTO_CONTINUE:-0}" = "1" ] && legacy_default=tmux
    m=$(_cfg::get BATON_AUTO_CONTINUE_MODE "$legacy_default" auto_continue_mode)
    case "$m" in tmux|relaunch|off) printf '%s' "$m" ;; *) printf 'off' ;; esac
  }
fi
[ "$(_cfg::auto_continue_mode)" = "relaunch" ] || exit 0

# ---- Past this point every path is COMMITTED and must leave a record ----
# (design guard rail: no silent failure paths.)

# Fire-once via a DEDICATED marker. Kept separate from the done-flag because that
# flag is ALSO the checkpoint block-gate (context-checkpoint.sh) - consuming it here
# would disarm the gate for the still-live session.
if ! ( set -o noclobber; : > "${DONE_FLAG}.relaunch-fired" ) 2>/dev/null; then
  exit 0   # already armed this checkpoint: not a failure, not a second record
fi

HELPER="${BATON_RELAUNCH_BIN:-$SCRIPT_DIR/../../tools/baton-relaunch.sh}"
if [ ! -f "$HELPER" ]; then
  # The fire-once claim is already burned, so no retry is possible this checkpoint.
  # Never exit silently here: a broken install would look identical to "nothing to do".
  _log "fail-helper-missing sid=$SESSION_ID helper=$HELPER"
  exit 0
fi

_log "armed sid=$SESSION_ID sup=$BATON_RELAUNCH_SUPERVISOR"

# Detached so this hook returns immediately and the turn ends cleanly. Mirrors the
# setsid/nohup guard at checkpoint-write-trigger.sh:293-297 (nohup fallback for
# hosts without setsid).
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$HELPER" "$SESSION_ID" "$BATON_RELAUNCH_SUPERVISOR" "$BATON_RELAUNCH_REQ" \
    >/dev/null 2>&1 </dev/null &
else
  nohup bash "$HELPER" "$SESSION_ID" "$BATON_RELAUNCH_SUPERVISOR" "$BATON_RELAUNCH_REQ" \
    >/dev/null 2>&1 </dev/null &
fi
disown 2>/dev/null || true
exit 0
