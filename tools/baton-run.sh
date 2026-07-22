#!/usr/bin/env bash
# Pass the Baton launcher. Reads the configured auto-continue driver and launches
# claude accordingly: the fresh-relaunch supervisor loop, inside tmux (so the
# post-checkpoint injector has a pane), or a plain passthrough. Launch this INSTEAD
# of `claude`; args pass through. See docs/configuration.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/hooks/lib/workstream-lib.sh" 2>/dev/null || true
# Driver selector lives in lib/config.sh (_cfg::auto_continue_mode -> off|tmux|relaunch).
if ! declare -F _cfg::auto_continue_mode >/dev/null 2>&1; then
  source "$SCRIPT_DIR/../lib/config.sh" 2>/dev/null || true
fi

CLAUDE_BIN="${_CLAUDE_BIN:-claude}"   # test seam, underscore-private: not a public knob
TMUX_BIN="${_TMUX_BIN:-tmux}"         # test seam

# Fresh-relaunch supervisor (E6 driver option 2). All relaunch-specific env is set
# HERE, not at top level, so tmux/off launches never carry the supervisor signal.
_run_relaunch() {
  : "${BATON_RELAUNCH_MAX:=10}"
  : "${BATON_RELAUNCH_LOG:=${TMPDIR:-/tmp}/baton-relaunch.log}"
  # Pin terminal identity for the whole run so every relaunch re-binds the SAME
  # workstream record and the progress file is re-injected.
  : "${CLAUDE_TERMINAL_ID:=baton-run-$$-$(date +%s)}"
  export CLAUDE_TERMINAL_ID
  # Presence of this var is the Stop hook's "a supervisor exists" signal.
  export BATON_RELAUNCH_SUPERVISOR=$$
  local _th; _th=$(term_hash 2>/dev/null || printf '%s' "$$")
  export BATON_RELAUNCH_REQ="${TMPDIR:-/tmp}/baton-relaunch-${_th}"
  _log() { printf '%s sup=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$1" >> "$BATON_RELAUNCH_LOG" 2>/dev/null || true; }
  # Fail CLOSED on a non-numeric cap: [ 1 -gt ten ] errors (rc=2) which `if` reads
  # as false, so an unguarded cap never fires.
  case "$BATON_RELAUNCH_MAX" in
    ''|*[!0-9]*) _log "warn-bad-relaunch-max value=$BATON_RELAUNCH_MAX using=10"; BATON_RELAUNCH_MAX=10 ;;
  esac
  local _iter=0
  while :; do
    rm -f "$BATON_RELAUNCH_REQ"
    "$CLAUDE_BIN" "$@"   # foreground; exit code deliberately ignored
    [ -f "$BATON_RELAUNCH_REQ" ] || break   # no marker = user-initiated exit = done
    rm -f "$BATON_RELAUNCH_REQ"
    _iter=$((_iter + 1))
    if [ "$_iter" -gt "$BATON_RELAUNCH_MAX" ]; then
      _log "stop-relaunch-cap-reached max=$BATON_RELAUNCH_MAX"
      echo "[baton] relaunch cap ($BATON_RELAUNCH_MAX) reached - stopping. Run baton again to continue." >&2
      break
    fi
    _log "relaunch iter=$_iter"
  done
}

# tmux driver: the injector sends /clear + a nudge into the pane claude runs in, so
# claude must run inside tmux. Already inside -> just exec. Outside -> start a session.
# tmux unavailable -> warn and fall back to a plain launch so the alias never dead-ends.
_run_tmux() {
  if [ -n "${TMUX:-}" ]; then
    exec "$CLAUDE_BIN" "$@"
  fi
  if command -v "$TMUX_BIN" >/dev/null 2>&1; then
    # -e BATON_AUTO_CONTINUE=1: the injector (baton-auto-continue.sh:12) hard-gates on this
    # legacy opt-in, and the checkpoint-write-trigger hook that spawns the injector inherits
    # claude's environment, so the tmux pane's claude must carry the flag or the
    # post-checkpoint /clear+nudge never fires (auto_continue_mode=tmux alone does not reach
    # the injector's line-12 gate; its config source is loaded AFTER that gate). tmux -e on
    # 'new-session -e' (set the pane's env) needs tmux >= 3.0, and preserves per-arg quoting
    # (unlike an env VAR=1 $* string). command -v only proves tmux is INSTALLED, not that it
    # supports -e; on tmux 2.x exec'ing the -e form errors and, since exec already replaced
    # this process, control never returns and the alias dead-ends. Gate on the version and
    # degrade to a plain launch + warn on older tmux so the alias never dead-ends.
    local _tv; _tv="$("$TMUX_BIN" -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$_tv" ] && awk "BEGIN{exit !($_tv >= 3.0)}"; then
      exec "$TMUX_BIN" new-session -e BATON_AUTO_CONTINUE=1 "$CLAUDE_BIN" "$@"
    fi
    echo "[baton] tmux ${_tv:-?} lacks 'new-session -e' (need >= 3.0) - launching claude without auto-continue." >&2
    exec "$CLAUDE_BIN" "$@"
  fi
  echo "[baton] auto_continue_mode=tmux but tmux is not installed - launching claude without it." >&2
  exec "$CLAUDE_BIN" "$@"
}

_mode="$(_cfg::auto_continue_mode 2>/dev/null || echo off)"
case "$_mode" in
  relaunch) _run_relaunch "$@" ;;
  tmux)     _run_tmux "$@" ;;
  *)        exec "$CLAUDE_BIN" "$@" ;;
esac
