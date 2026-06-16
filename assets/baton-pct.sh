#!/bin/bash
# baton-pct.sh - statusline shim for checkpoint context percentage.
# Emits a short context indicator for use in shell prompts or Claude Code statusline.
#
# Usage (append to ~/.claude/statusline.sh before the final echo):
#   bash "$CLAUDE_PROJECT_DIR/assets/baton-pct.sh" "$SESSION_ID"
#
# Emits nothing if PCT file is absent (statusline not yet populated).
# Emits "CTX:NN%" where NN is the current context fill percentage.
# Emits "CTX:DONE" if a checkpoint-done flag is set for this session.

SESSION_ID="${1:-${SESSION_ID:-}}"
[ -z "$SESSION_ID" ] && exit 0

PCT_FILE="/tmp/claude-context-pct-${SESSION_ID}"
DONE_FILE="/tmp/baton-done-${SESSION_ID}"

if [ -f "$DONE_FILE" ]; then
  printf 'CTX:DONE'
  exit 0
fi

if [ ! -f "$PCT_FILE" ]; then
  exit 0
fi
PCT=$(cat "$PCT_FILE" 2>/dev/null)
[ -z "$PCT" ] && exit 0

MODE="${BATON_STATUSLINE_COLOR_MODE:-off}"
case "$MODE" in
  off)
    printf 'CTX:%s%%' "$PCT"
    ;;
  solid)
    # Threshold hardcoded at 80 (iter-3 plan-review: env-var SOLID_THRESHOLD knob dropped - no dashboard consumer).
    if [ "$PCT" -ge 80 ] 2>/dev/null; then
      printf '\033[31mCTX:%s%%\033[0m' "$PCT"
    else
      printf 'CTX:%s%%' "$PCT"
    fi
    ;;
  bands)
    if [ "$PCT" -ge 80 ] 2>/dev/null; then
      printf '\033[31mCTX:%s%%\033[0m' "$PCT"
    elif [ "$PCT" -ge 50 ] 2>/dev/null; then
      printf '\033[33mCTX:%s%%\033[0m' "$PCT"
    else
      printf '\033[32mCTX:%s%%' "$PCT"
      printf '\033[0m'
    fi
    ;;
  *)
    # unknown mode: behave as off (safe default)
    printf 'CTX:%s%%' "$PCT"
    ;;
esac
