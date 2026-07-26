#!/usr/bin/env bash
# baton-consent.sh - resolve the post-write consent question for a MANUAL
# checkpoint. Invoked by the model after it has asked the user, per the
# instruction checkpoint-write-trigger.sh emits once the manual progress file
# lands. Two verbs:
#   keep  - user continues in this session. Drop the consent marker, leave the DONE
#           flag unlatched, and CLEAR THE TRIGGER FLAG. That last part is
#           load-bearing: the write-trigger has already removed PENDING, and
#           context-checkpoint.sh short-circuits on `FLAG set + PENDING absent`
#           (its :216-217), so a surviving FLAG would block the threshold re-arm at
#           :443 and the PENDING write at :556 for the rest of the session - killing
#           both automatic checkpointing AND any later /renew, silently. Clearing it
#           returns the session to its pre-checkpoint state, which is exactly what
#           "keep working" means.
#   clear - user is done. Latch the DONE flag exactly as an automated save does, so
#           the post-checkpoint block and both auto-continue drivers
#           (stop-relaunch-trigger.sh, baton-auto-continue.sh) behave unchanged.
#           FLAG is deliberately left alone here: the DONE guard owns the session
#           from this point and cleanup-on-exit.sh reaps FLAG at SessionEnd.
# Refuses when no consent is outstanding, so it cannot latch DONE out of band.
set -u
SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SID" ]; then
  echo "baton: cannot resolve consent - CLAUDE_CODE_SESSION_ID is not set." >&2
  exit 1
fi
case "$SID" in
  *[!A-Za-z0-9_-]*)
    echo "baton: refusing to resolve consent - session id has unexpected characters." >&2
    exit 1 ;;
esac
VERB="${1:-}"
case "$VERB" in
  keep|clear) ;;
  *)
    echo "baton: usage: baton-consent.sh keep|clear" >&2
    exit 1 ;;
esac
CONSENT="/tmp/baton-consent-${SID}"
if [ ! -f "$CONSENT" ]; then
  echo "baton: no checkpoint consent is outstanding for this session." >&2
  exit 1
fi
if [ "$VERB" = clear ]; then
  touch "/tmp/baton-done-${SID}" || { echo "baton: could not latch done flag." >&2; exit 1; }
  rm -f "$CONSENT"
  echo "baton: checkpoint closed. Tell the user to /clear." >&2
else
  rm -f "/tmp/claude-context-triggered-${SID}"
  rm -f "$CONSENT"
  echo "baton: continuing in this session. Checkpointing is re-armed for the next threshold crossing." >&2
fi
