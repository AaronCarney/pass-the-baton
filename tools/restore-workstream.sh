#!/bin/bash
# restore-workstream.sh <ws-id>
# Copies an archived workstream record back to the live tracking dir.
# If the workstream's progress_file points at a missing path, also restores
# the matching archived progress file from ${BATON_ARCHIVE_DIR}/progress/<YYYY-MM>/.
# Idempotent: re-running on an already-restored workstream is a no-op.
#
# Usage: bash tools/restore-workstream.sh <ws-id>
set -u

WS_ID="${1:-}"
if [ -z "$WS_ID" ]; then
  echo "ERROR: missing workstream id" >&2
  echo "Usage: bash tools/restore-workstream.sh <ws-id>" >&2
  exit 1
fi

if ! [[ "$WS_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: invalid workstream id '$WS_ID' - must match [a-zA-Z0-9_-]+" >&2
  exit 1
fi

# Source the shared lib for archive_dir + checkpoint_dir.
PROJECT_DIR="${BATON_PROJECT_DIR:-${OLORIN_PROJECT_DIR:-$PWD}}"
# Resolve the library relative to THIS script so the CLI works for a plugin
# install (script lives under ${CLAUDE_PLUGIN_ROOT}) and a clone alike; fall back
# to the consumer-project layout for legacy by-reference installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOKS_LIB="$SCRIPT_DIR/../.claude/hooks/lib/workstream-lib.sh"
[ -f "$HOOKS_LIB" ] || HOOKS_LIB="$PROJECT_DIR/.claude/hooks/lib/workstream-lib.sh"
if [ ! -f "$HOOKS_LIB" ]; then
  echo "ERROR: workstream-lib.sh not found (looked in $SCRIPT_DIR/../.claude/hooks/lib and $PROJECT_DIR/.claude/hooks/lib)" >&2
  exit 2
fi
source "$HOOKS_LIB"

# Precedence (matches E4-T5/T6 pattern): BATON_ARCHIVE_DIR > OLORIN_ARCHIVE_DIR > $(archive_dir) default.
ARCHIVE="${BATON_ARCHIVE_DIR:-${OLORIN_ARCHIVE_DIR:-$(archive_dir)}}"
if [ -n "${OLORIN_ARCHIVE_DIR:-}" ] && [ -z "${BATON_ARCHIVE_DIR:-}" ]; then
  echo "WARN: OLORIN_ARCHIVE_DIR is deprecated - use BATON_ARCHIVE_DIR instead." >&2
fi
TRACKING="$(checkpoint_dir "$PROJECT_DIR")"
mkdir -p "$TRACKING/workstreams"

# Find the latest archived copy across all <YYYY-MM> partitions.
LATEST_ARCHIVE=""
LATEST_TS=0
for f in "$ARCHIVE/checkpoint-state"/*/workstreams/"${WS_ID}.json"; do
  [ -f "$f" ] || continue
  ts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  if [ "$ts" -gt "$LATEST_TS" ]; then
    LATEST_TS="$ts"
    LATEST_ARCHIVE="$f"
  fi
done

if [ -z "$LATEST_ARCHIVE" ]; then
  echo "ERROR: no archived workstream record matching '$WS_ID' under $ARCHIVE/checkpoint-state/*/workstreams/" >&2
  exit 3
fi

DEST="$TRACKING/workstreams/${WS_ID}.json"
if [ -f "$DEST" ]; then
  echo "Note: $DEST already exists - leaving alone (idempotent no-op)."
else
  cp "$LATEST_ARCHIVE" "$DEST"
  echo "Restored workstream record: $DEST"
fi

# Restore progress file if its path is set and the target is missing.
PROG=$(jq -r '.progress_file // empty' "$DEST" 2>/dev/null)
if [ -n "$PROG" ] && [ ! -f "$PROG" ]; then
  PROG_BASE=$(basename "$PROG")
  for pf in "$ARCHIVE/progress"/*/"$PROG_BASE"; do
    [ -f "$pf" ] || continue
    mkdir -p "$(dirname "$PROG")"
    cp "$pf" "$PROG"
    echo "Restored progress file: $PROG"
    break
  done
fi

exit 0
