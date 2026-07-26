#!/usr/bin/env bash
# baton-unlock.sh - fully disable Pass the Baton checkpointing for THIS session.
# Invoked by /pass-the-baton:off. Writes a per-session unlock flag that
# context-checkpoint.sh honors by no-opping the entire checkpoint lifecycle
# (no trigger, no gate, no nag) until the session ends. The design's 'all the
# way off'. Cleared at SessionEnd / by the /tmp sweep.
set -u
SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SID" ]; then
  echo "baton: cannot unlock - CLAUDE_CODE_SESSION_ID is not set." >&2
  exit 1
fi
case "$SID" in
  *[!A-Za-z0-9_-]*)
    echo "baton: refusing to unlock - session id has unexpected characters." >&2
    exit 1 ;;
esac
UNLOCK="/tmp/baton-unlock-${SID}"
: > "$UNLOCK" || { echo "baton: could not write unlock flag $UNLOCK" >&2; exit 1; }
echo "baton: checkpointing disabled for this session. Start a new session to re-enable." >&2
