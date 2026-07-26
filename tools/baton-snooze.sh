#!/usr/bin/env bash
# baton-snooze.sh - briefly defer Pass the Baton checkpointing for THIS session.
# Invoked by /pass-the-baton:snooze [minutes] (default 10). Writes a per-session
# flag whose CONTENTS are an absolute expiry epoch; context-checkpoint.sh
# suppresses checkpointing while now < expiry, then removes the stale flag.
set -u
SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SID" ]; then
  echo "baton: cannot snooze - CLAUDE_CODE_SESSION_ID is not set." >&2
  exit 1
fi
case "$SID" in
  *[!A-Za-z0-9_-]*)
    echo "baton: refusing to snooze - session id has unexpected characters." >&2
    exit 1 ;;
esac
MINUTES="${1:-10}"
case "$MINUTES" in
  ''|*[!0-9]*)
    echo "baton: snooze minutes must be a positive integer (got '$MINUTES')." >&2
    exit 1 ;;
esac
[ "$MINUTES" -eq 0 ] && { echo "baton: snooze minutes must be > 0." >&2; exit 1; }
# Bounded on purpose: an unbounded snooze silently disables the whole continuity
# layer for days behind one line of stderr. Deferring longer than this is a
# decision to stop checkpointing, which is what /pass-the-baton:off is for.
BATON_SNOOZE_MAX_MIN="${BATON_SNOOZE_MAX_MIN:-120}"
if [ "$MINUTES" -gt "$BATON_SNOOZE_MAX_MIN" ]; then
  echo "baton: snooze capped at ${BATON_SNOOZE_MAX_MIN} min (got ${MINUTES}). Use /pass-the-baton:off to disable checkpointing for this session." >&2
  exit 1
fi
EXPIRY=$(( $(date +%s) + MINUTES * 60 ))
SNOOZE="/tmp/baton-snooze-${SID}"
printf '%s' "$EXPIRY" > "$SNOOZE" || { echo "baton: could not write snooze flag $SNOOZE" >&2; exit 1; }
if [ -f "/tmp/baton-pending-${SID}" ]; then
  echo "baton: WARNING - this session has an UNSAVED CHECKPOINT owed. Snoozing defers the reminder, not the obligation: if the session compacts before you write the progress file, the handoff is lost. Deny the next prompt to save now, or run /pass-the-baton:renew when the snooze expires." >&2
fi
echo "baton: checkpointing snoozed for ${MINUTES} min (this session)." >&2
