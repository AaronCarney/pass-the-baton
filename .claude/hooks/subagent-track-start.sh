#!/usr/bin/env bash
# SubagentStart hook. Records an active-subagent marker so the parent's checkpoint
# write can be HELD until every in-flight subagent has returned (drain protection).
# Payload: agent_id (+ agent_type, session_id = the SUBAGENT's). There is NO parent
# field, so attribute to the parent via the term_hash -> parent-sid map the parent
# wrote at session start (subagents inherit CLAUDE_TERMINAL_ID, so term_hash here
# resolves to the PARENT terminal). Best-effort: never block the subagent.
set -u
input=$(cat)
AGENT_ID=$(printf '%s' "$input" | jq -r '.agent_id // empty')
[ -z "$AGENT_ID" ] && exit 0

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOKS_DIR/lib/workstream-lib.sh" 2>/dev/null || true
source "$HOOKS_DIR/lib/drain-gate.sh" 2>/dev/null || exit 0

declare -F term_hash >/dev/null 2>&1 || exit 0
TERM_HASH=$(term_hash 2>/dev/null || echo "")
[ -z "$TERM_HASH" ] && exit 0
PARENT_SID=$(cat "/tmp/claude-parent-sid-${TERM_HASH}" 2>/dev/null || echo "")
[ -z "$PARENT_SID" ] && exit 0

drain::mark_start "$PARENT_SID" "$AGENT_ID" || true
exit 0
