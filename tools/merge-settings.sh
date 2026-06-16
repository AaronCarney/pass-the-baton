#!/bin/bash
# merge-settings.sh - idempotent merge of checkpoint hooks into a Claude Code
# settings.json. Reads our hook entries from a static spec, then either adds
# them (default) or removes them (--remove). Matches existing entries by exact
# command path so re-runs are no-ops.
#
# Parallel indexed arrays (EVENTS/MATCHERS/COMMANDS) allow multiple rows per
# event key - necessary because PostToolUse and UserPromptSubmit each have two
# distinct hook registrations that would collide in a bash associative array.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOKS_DIR="$REPO_DIR/.claude/hooks"

MODE="add"
if [ "${1:-}" = "--remove" ]; then
  MODE="remove"
  shift
fi

TARGET="${1:?usage: merge-settings.sh [--remove] <settings.json>}"

# Parallel indexed arrays: one row per hook registration (event, matcher, command).
# Multiple rows per event-name are allowed (shipped settings.json schema is
# `.hooks.<event>` as an ARRAY of {matcher, hooks[]} entries - claude-code merges them).
EVENTS=(
  SessionStart
  PreToolUse
  PostToolUse
  PostToolUse
  SessionEnd
  UserPromptSubmit
  UserPromptSubmit
)
MATCHERS=(
  ""
  ""
  "Write|Edit|MultiEdit"
  "Bash"
  ""
  ""
  ""
)
COMMANDS=(
  "bash $HOOKS_DIR/session-start.sh"
  "bash $HOOKS_DIR/context-checkpoint.sh"
  "bash $HOOKS_DIR/checkpoint-write-trigger.sh"
  "bash $HOOKS_DIR/outcome-proxy-code-execution.sh"
  "bash $HOOKS_DIR/cleanup-on-exit.sh"
  "bash $HOOKS_DIR/project-detect.sh"
  "bash $HOOKS_DIR/outcome-proxy-retry-density.sh"
)

if [ -f "$TARGET" ] && [ -s "$TARGET" ]; then
  CURRENT=$(cat "$TARGET")
else
  CURRENT="{}"
fi

NEXT="$CURRENT"

for i in "${!EVENTS[@]}"; do
  EVENT="${EVENTS[$i]}"
  MATCHER="${MATCHERS[$i]}"
  CMD="${COMMANDS[$i]}"

  if [ "$MODE" = "remove" ]; then
    NEXT=$(echo "$NEXT" | jq --arg ev "$EVENT" --arg cmd "$CMD" '
      .hooks //= {}
      | (.hooks[$ev] // []) as $arr
      | .hooks[$ev] = ($arr | map(select(.hooks // [] | map(.command) | index($cmd) | not)))
      | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
    ')
  else
    HAS=$(echo "$NEXT" | jq --arg ev "$EVENT" --arg cmd "$CMD" '
      (.hooks[$ev] // []) | map(.hooks // [] | map(.command)) | flatten | index($cmd) | not | not
    ')
    if [ "$HAS" = "true" ]; then
      continue
    fi
    NEXT=$(echo "$NEXT" | jq --arg ev "$EVENT" --arg cmd "$CMD" --arg matcher "$MATCHER" '
      .hooks //= {}
      | .hooks[$ev] //= []
      | .hooks[$ev] += [{"matcher": $matcher, "hooks": [{"type": "command", "command": $cmd}]}]
    ')
  fi
done

TMP=$(mktemp "${TARGET}.XXXXXX")
echo "$NEXT" | jq '.' > "$TMP"
mv "$TMP" "$TARGET"
