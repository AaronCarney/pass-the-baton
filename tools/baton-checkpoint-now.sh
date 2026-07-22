#!/usr/bin/env bash
# baton-checkpoint-now.sh - arm an immediate checkpoint for THIS Claude Code session.
# Invoked by the /pass-the-baton:renew command. Writes a per-session force flag that
# context-checkpoint.sh consumes on its next PreToolUse fire, running the exact same
# checkpoint path as a %-threshold crossing (context-% independent). One-shot.
set -u

SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SID" ]; then
  echo "baton: cannot arm checkpoint - CLAUDE_CODE_SESSION_ID is not set." >&2
  exit 1
fi
# The id becomes a /tmp filename component; reject anything but the known-safe set.
# Charset matches context-checkpoint.sh's own SESSION_ID guard (^[a-zA-Z0-9_-]+$) so
# an armed flag is never orphaned by a session the hook would itself reject.
case "$SID" in
  *[!A-Za-z0-9_-]*)
    echo "baton: refusing to arm - session id has unexpected characters." >&2
    exit 1 ;;
esac
FORCE="/tmp/baton-force-checkpoint-${SID}"
: > "$FORCE" || { echo "baton: could not write force flag $FORCE" >&2; exit 1; }
echo "baton: checkpoint armed for this session - it will save on your next action." >&2
