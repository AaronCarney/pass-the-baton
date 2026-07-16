#!/usr/bin/env bash
# Pass the Baton - interactive fresh-relaunch supervisor (E6 driver option 2).
# Launch this INSTEAD of `claude`. On a checkpoint the session exits and a fresh
# `claude` relaunches in this same terminal; SessionStart re-injects the progress
# file, which is a clear-and-continue without tmux and without keystroke injection.
# No hook can end a session from the inside, so this external supervisor is the
# minimum viable structure - see docs/configuration.md, "Fresh-relaunch driver".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/hooks/lib/workstream-lib.sh" 2>/dev/null || true

CLAUDE_BIN="${_CLAUDE_BIN:-claude}"   # test seam, underscore-private: not a public knob
: "${BATON_RELAUNCH_MAX:=10}"
: "${BATON_RELAUNCH_LOG:=${TMPDIR:-/tmp}/baton-relaunch.log}"

# Pin terminal identity for the whole run: term_hash() reads CLAUDE_TERMINAL_ID
# first, so every relaunch re-binds to the SAME workstream record and the progress
# file is re-injected. Also immune to the reused-tty collision a bare $(tty) hash has.
: "${CLAUDE_TERMINAL_ID:=baton-run-$$-$(date +%s)}"
export CLAUDE_TERMINAL_ID

# Presence of this var is the hook's "a supervisor exists" signal. Without it the
# Stop hook no-ops, so plain `claude` users are untouched. MEASURED to reach the
# hook's env (2026-07-14 run 2).
export BATON_RELAUNCH_SUPERVISOR=$$

# This wrapper OWNS the request path (never injectable): the hook must not have to
# recompute term_hash, and a caller-supplied path could point anywhere.
_th=$(term_hash 2>/dev/null || printf '%s' "$$")
export BATON_RELAUNCH_REQ="${TMPDIR:-/tmp}/baton-relaunch-${_th}"

_log() {
  printf '%s sup=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$1" >> "$BATON_RELAUNCH_LOG" 2>/dev/null || true
}

# A typo must not buy unbounded relaunching: `[ 1 -gt ten ]` does not return false,
# it errors (rc=2), which `if` reads as false - so an unguarded cap never fires and
# the only backstop against a pathological relaunch cycle is gone. Fail CLOSED.
# Must sit after _log() is defined. The private _RELAUNCH_GRACE seam already has
# this guard (baton-relaunch.sh); the public documented knob had none.
case "$BATON_RELAUNCH_MAX" in
  ''|*[!0-9]*) _log "warn-bad-relaunch-max value=$BATON_RELAUNCH_MAX using=10"; BATON_RELAUNCH_MAX=10 ;;
esac

_iter=0
while :; do
  # Never honor a marker left by anything but THIS launch.
  rm -f "$BATON_RELAUNCH_REQ"

  "$CLAUDE_BIN" "$@"   # foreground: claude owns the TTY. Exit code is deliberately ignored.

  # The marker means the helper killed it FOR a relaunch. A user-initiated exit
  # leaves no marker, so the loop ends - that is the normal way out.
  [ -f "$BATON_RELAUNCH_REQ" ] || break
  rm -f "$BATON_RELAUNCH_REQ"

  _iter=$((_iter + 1))
  if [ "$_iter" -gt "$BATON_RELAUNCH_MAX" ]; then
    _log "stop-relaunch-cap-reached max=$BATON_RELAUNCH_MAX"
    echo "[baton] relaunch cap ($BATON_RELAUNCH_MAX) reached - stopping. Run baton-run again to continue." >&2
    break
  fi
  _log "relaunch iter=$_iter"
done
