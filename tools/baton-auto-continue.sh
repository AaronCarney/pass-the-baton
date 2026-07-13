#!/usr/bin/env bash
# E6 same-terminal automation injector. Detached background process spawned by
# checkpoint-write-trigger.sh AFTER a checkpoint write completes. Sends /clear +
# a continue nudge into the tmux pane the session runs in, so the human does not
# have to. Opt-in (BATON_AUTO_CONTINUE=1), tmux-only; clean no-op otherwise.
# Usage: baton-auto-continue.sh <session_id> <done_flag_path> <pane_id>
set -u

SID="${1:-}"; DONE_FLAG="${2:-}"; PANE="${3:-}"

# Opt-in gate + preconditions. Any miss -> silent clean no-op.
[ "${BATON_AUTO_CONTINUE:-0}" = "1" ] || exit 0
[ -n "$PANE" ] || exit 0
[ -n "$DONE_FLAG" ] && [ -e "$DONE_FLAG" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

: "${_AUTO_CONTINUE_POLL_INTERVAL:=0.3}"   # seconds between pane-readiness polls
: "${_AUTO_CONTINUE_POLL_MAX_SECONDS:=60}" # bounded max-wait, then give up cleanly
: "${BATON_AUTO_CONTINUE_NUDGE:=proceed}"  # text sent after /clear to start the model
: "${BATON_AUTO_CONTINUE_LOG:=${TMPDIR:-/tmp}/baton-auto-continue.log}"  # audit trail

# Observability (owner rule: no failure path ends silently). Once the fire-once
# marker (`.fired`) is claimed the injector is COMMITTED, so every terminal state
# past that point writes exactly one line here. Pre-commit gate misses stay silent
# no-ops - logging every checkpoint would be noise.
_log() {
  printf '%s sid=%s pane=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$PANE" "$1" \
    >> "$BATON_AUTO_CONTINUE_LOG" 2>/dev/null || true
}

# Poll the pane until its input line looks idle/ready (a trailing prompt with an
# empty input), or the bounded budget elapses. Returns 0 if ready, 1 on timeout.
_wait_ready() {
  local max="$_AUTO_CONTINUE_POLL_MAX_SECONDS" snap
  # integer loop bound: max/interval, computed with awk (interval is fractional)
  local iters; iters=$(awk -v m="$max" -v i="$_AUTO_CONTINUE_POLL_INTERVAL" 'BEGIN{printf "%d", (i>0)? m/i : 0}')
  local n=0
  while [ "$n" -lt "$iters" ]; do
    snap=$(tmux capture-pane -t "$PANE" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
    # Idle heuristic: the last non-blank pane line is a prompt line (ends with a
    # prompt glyph and no in-flight text). Kept permissive on purpose - a false
    # "ready" only means the nudge waits in the input box; a false "busy" only
    # delays up to the budget. Either way we never corrupt an in-flight turn
    # because we abort-on-timeout rather than force-send.
    case "$snap" in
      *'$ '|*'> '|*'# '|*'❯ '|*'│ ') return 0 ;;
    esac
    n=$((n+1)); sleep "$_AUTO_CONTINUE_POLL_INTERVAL"
  done
  return 1
}

# 1. Wait for the checkpoint turn to finish (idle input) before touching anything.
# Flag NOT yet consumed here -> a timeout is the clean no-op (user acts manually,
# flag intact). Logged so an enabled-but-never-fired session is still diagnosable.
_wait_ready || { _log noop-idle-wait-timeout; exit 0; }

# 2. Abort check. Deleting the done-flag during the _wait_ready poll above is the
# user's abort control -> clean exit, no keys sent. We only READ the flag; we do
# NOT consume it, because it is ALSO the checkpoint block-gate (context-checkpoint.sh:
# "do not continue working"). Removing it here would disarm that gate for the still-
# live session if a later send fails. (A post-spawn env re-check is impossible: this
# process is detached, so its BATON_AUTO_CONTINUE was frozen at spawn.)
[ -e "$DONE_FLAG" ] || { _log noop-aborted-flag-gone; exit 0; }

# Fire-once via a DEDICATED marker, atomically claimed with noclobber so a second
# injector for the same session loses the race and no-ops - kept separate from the
# block-gate flag so fire-once never disarms the gate. cleanup-on-exit.sh removes
# both the flag and this marker at session end; a successful /clear starts a fresh
# session that no longer keys on either.
if ! ( set -o noclobber; : > "${DONE_FLAG}.fired" ) 2>/dev/null; then
  _log noop-already-fired; exit 0
fi

# 3. Send /clear (Enter = C-m; never the literal string "\n").
tmux send-keys -t "$PANE" "/clear" Enter 2>/dev/null || { _log fail-clear-send; exit 0; }

# 4. Wait for the fresh session's prompt, then send the nudge as literal text. If the
# prompt never becomes ready the session is CLEARED-BUT-NOT-CONTINUED - the one
# consequential failure state - so it MUST leave a record instead of vanishing.
_wait_ready || { _log cleared-not-continued-prompt-timeout; exit 0; }
# Guard both sends: a failure here (pane died between poll and send) must NOT be
# recorded as `continued`. An accurate terminal record is the owner rule.
tmux send-keys -t "$PANE" -l -- "$BATON_AUTO_CONTINUE_NUDGE" 2>/dev/null || { _log fail-nudge-send; exit 0; }
tmux send-keys -t "$PANE" Enter 2>/dev/null || { _log fail-nudge-send; exit 0; }
_log continued
exit 0
