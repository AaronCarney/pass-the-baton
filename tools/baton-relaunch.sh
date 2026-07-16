#!/usr/bin/env bash
# Pass the Baton - fresh-relaunch helper (E6 driver option 2). Detached process
# spawned by the Stop hook after a checkpoint write. Terminates the session so the
# baton-run supervisor can start a fresh one. Opt-in; every precondition miss is a
# clean no-op. Usage: baton-relaunch.sh <session_id> <supervisor_pid> <req_path>
set -u

SID="${1:-}"; SUP="${2:-}"; REQ="${3:-}"
[ -n "$SID" ] && [ -n "$SUP" ] && [ -n "$REQ" ] || exit 0

# Underscore-private: these are TEST SEAMS, not public knobs. A BATON_* name would
# promise support we do not offer. Precedent: baton-auto-continue.sh:17-18.
: "${_RELAUNCH_SETTLE:=1}"   # let the Stop hook return + the turn render
: "${_RELAUNCH_GRACE:=5}"    # SIGTERM -> SIGKILL escalation (measured need: 0.75s)
: "${_RELAUNCH_KILL:=kill}"  # seam: the ONLY way to induce the fail-sigterm branch
: "${BATON_RELAUNCH_LOG:=${TMPDIR:-/tmp}/baton-relaunch.log}"

# A non-numeric grace would make awk yield 0 below -> straight to SIGKILL, skipping
# SessionEnd on every relaunch. Fall back to the default rather than escalate blind.
case "$_RELAUNCH_GRACE" in
  ''|*[!0-9.]*) _RELAUNCH_GRACE=5 ;;
esac

_log() {
  printf '%s sid=%s sup=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$SUP" "$1" \
    >> "$BATON_RELAUNCH_LOG" 2>/dev/null || true
}

sleep "$_RELAUNCH_SETTLE"

# Without pgrep we cannot constrain the target, and killing an unconstrained PID is
# never acceptable. Distinct tag: a broken host is not a user who quit.
command -v pgrep >/dev/null 2>&1 || { _log noop-no-pgrep; exit 0; }

# Re-resolve at fire time. NEVER trust a PID passed in: the user may have quit and
# the PID been recycled. Two constraints at once - named `claude` AND a direct child
# of OUR supervisor - so a recycled PID cannot be hit. `baton-run` invokes `claude` by
# name, so the basename always matches.
PID=$(pgrep -P "$SUP" claude 2>/dev/null | head -1)
[ -n "$PID" ] || { _log noop-no-claude-child; exit 0; }
"$_RELAUNCH_KILL" -0 "$PID" 2>/dev/null || { _log noop-child-gone; exit 0; }

# Marker BEFORE the kill: claude takes ~750ms to exit, so the marker is always on
# disk before the supervisor regains control. Written here (not in the hook) so a
# user-initiated quit never leaves one behind.
# Braces matter: `! : > "$REQ" 2>/dev/null` applies the redirections left-to-right,
# so the failing `> "$REQ"` reports to the real stderr before 2>/dev/null binds.
# Grouping puts the suppression around the whole redirection.
if ! { : > "$REQ"; } 2>/dev/null; then _log fail-marker-write; exit 0; fi

if ! "$_RELAUNCH_KILL" -TERM "$PID" 2>/dev/null; then
  rm -f "$REQ"   # no kill -> no relaunch. Never strand a marker.
  _log fail-sigterm; exit 0
fi

# Bounded wait, then escalate. SIGKILL skips SessionEnd (state leaks, swept later by
# cleanup-cron) so it is recorded as degraded, not success.
_n=0; _max=$(awk -v g="$_RELAUNCH_GRACE" 'BEGIN{printf "%d", g/0.25}')
while [ "$_n" -lt "$_max" ]; do
  "$_RELAUNCH_KILL" -0 "$PID" 2>/dev/null || { _log "relaunch-requested pid=$PID"; exit 0; }
  _n=$((_n + 1)); sleep 0.25
done
"$_RELAUNCH_KILL" -KILL "$PID" 2>/dev/null
_log "degraded-sigkill pid=$PID (ignored SIGTERM for ${_RELAUNCH_GRACE}s; SessionEnd skipped)"
exit 0
