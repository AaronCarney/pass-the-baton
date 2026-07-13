#!/bin/bash
# UserPromptSubmit hook. Watches user prompts for two signals:
#   - mention of a project under projects/<name>
#   - explicit "rename this session to X"
# Project mention: if another workstream already owns that display_name, REBIND
# this terminal to it (terminals/<hash>.json) - the user is switching back to
# existing work; otherwise claim the name for the bound workstream (no suffix).
# Explicit rename: relabel the bound workstream's display_name, suffixing on
# collision; the binding is unchanged.
# Subagents (AGENT_SESSION_ID set) early-exit so they cannot rename or rebind
# their parent's terminal.
set -u

input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id')
PROMPT=$(echo "$input" | jq -r '.prompt // empty')
CWD=$(echo "$input" | jq -r '.cwd')
[ -z "$SESSION_ID" ] && exit 0
[ -z "$PROMPT" ] && exit 0
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/envelope.sh" 2>/dev/null || true

# Emit UserPromptSubmit envelope exactly once on EXIT. CC8: NEVER include the
# prompt content, only its byte length. Failures go to stderr, never alter
# the hook exit code.
_PD_BYTES=${#PROMPT}
_PD_SLUG=""
_PD_EMITTED=0
_emit_pd() {
  [ "$_PD_EMITTED" = "1" ] && return 0
  _PD_EMITTED=1
  local _data
  _data=$(jq -cn \
    --arg slug "$_PD_SLUG" \
    --argjson b "${_PD_BYTES:-0}" \
    '{project_slug:$slug, prompt_bytes:$b}' 2>/dev/null) || _data='{}'
  envelope::emit "UserPromptSubmit" "$_data" 2>/dev/null || true
}
trap _emit_pd EXIT

# Subagent: do NOT rename parent's workstream label.
[ -n "${AGENT_SESSION_ID:-}" ] && exit 0

source "$SCRIPT_DIR/lib/workstream-lib.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
TRACKING="$(checkpoint_dir "$PROJECT_DIR")"
[ -d "$TRACKING/workstreams" ] || exit 0

# Find current workstream from per-session tracking pointer
T_POINTER="/tmp/claude-session-tracking-${SESSION_ID}"
[ -f "$T_POINTER" ] || exit 0
T_FILE=$(cat "$T_POINTER")
[ -f "$T_FILE" ] || exit 0
CURRENT_WS=$(jq -r '.workstream // empty' "$T_FILE")
[ -z "$CURRENT_WS" ] && exit 0

WS_FILE="$TRACKING/workstreams/${CURRENT_WS}.json"
[ -f "$WS_FILE" ] || exit 0
EXISTING_NAME=$(jq -r '.display_name // empty' "$WS_FILE")

# Match prompt against project symlinks (lowercased word match)
MATCHED_PROJECT=""
for link in "$PROJECT_DIR"/projects/*/; do
  [ -L "${link%/}" ] || continue
  LINK_NAME=$(basename "${link%/}")
  LINK_LOWER=$(echo "$LINK_NAME" | tr '[:upper:]' '[:lower:]')
  if echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | grep -qw "$LINK_LOWER"; then
    MATCHED_PROJECT="$LINK_NAME"
    break
  fi
done

# "rename this session to X" - \K resets the match start, so -o emits only
# the trailing token. (Earlier `sed 's/.*session to //'` strip was
# case-sensitive and dropped uppercase variants like "Session TO".)
# DEPENDENCY: GNU grep (\K is a GNU-only PCRE feature; not in BSD/macOS grep).
# Documented in docs/install.md Platform Support; portability via `perl -ne` is
# deferred until macOS support is requested.
IS_RENAME=false
RENAME_MATCH=$(echo "$PROMPT" | grep -oiP 'rename\s+(?:this\s+)?session\s+to\s+\K\S+')
if [ -n "$RENAME_MATCH" ]; then
  MATCHED_PROJECT="$RENAME_MATCH"
  IS_RENAME=true
fi

_PD_SLUG="${MATCHED_PROJECT:-}"

[ -z "$MATCHED_PROJECT" ] && exit 0

# Same as the bound workstream's current label? no-op
[ "$(echo "$MATCHED_PROJECT" | tr '[:upper:]' '[:lower:]')" = "$(echo "$EXISTING_NAME" | tr '[:upper:]' '[:lower:]')" ] && exit 0

# Relabel the bound workstream's display_name under flock (jq+mv held together;
# the `flock <file> <cmd>` form releases too early). Never touches per-session tracking.
_pd_relabel() {
  local dn="$1" tmp
  tmp=$(mktemp -p "$(dirname "$WS_FILE")")
  exec 9>"${WS_FILE}.lock"
  flock 9
  jq --arg dn "$dn" '.display_name = $dn' "$WS_FILE" > "$tmp" && mv "$tmp" "$WS_FILE"
  flock -u 9
  exec 9>&-
}

if [ "$IS_RENAME" = true ]; then
  # Explicit "rename this session to X": claim the label for the bound workstream,
  # suffixing (X-2, X-3, …) to dodge collisions. The binding itself is unchanged.
  DISPLAY_NAME="$MATCHED_PROJECT"
  SUFFIX=1
  while true; do
    TAKEN=false
    for f in "$TRACKING"/workstreams/*.json; do
      [ -f "$f" ] || continue
      [ "$f" = "$WS_FILE" ] && continue
      P_NAME=$(jq -r '.display_name // empty' "$f")
      if [ "$(echo "$P_NAME" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DISPLAY_NAME" | tr '[:upper:]' '[:lower:]')" ]; then
        TAKEN=true; break
      fi
    done
    [ "$TAKEN" = false ] && break
    SUFFIX=$((SUFFIX + 1))
    DISPLAY_NAME="${MATCHED_PROJECT}-${SUFFIX}"
  done
  _pd_relabel "$DISPLAY_NAME"
else
  # Bare project mention. If a DIFFERENT workstream already owns this name, the
  # user is switching back to existing work → REBIND this terminal to it. The
  # binding (terminals/<hash>.json), not the label, is what the checkpoint WRITE
  # path resolves, so rebinding is the load-bearing fix for the /clear bug where a
  # project mention only relabeled-with-suffix and left the binding stale. Pick the
  # most-recently-updated match so a non-unique display_name resolves deterministically.
  TARGET_WS=""
  TARGET_EPOCH=-1
  MP_LOWER=$(echo "$MATCHED_PROJECT" | tr '[:upper:]' '[:lower:]')
  for f in "$TRACKING"/workstreams/*.json; do
    [ -f "$f" ] || continue
    [ "$f" = "$WS_FILE" ] && continue
    P_NAME=$(jq -r '.display_name // empty' "$f")
    [ "$(echo "$P_NAME" | tr '[:upper:]' '[:lower:]')" = "$MP_LOWER" ] || continue
    P_EPOCH=$(parse_iso8601 "$(jq -r '.updated_at // empty' "$f")")
    if [ "$P_EPOCH" -gt "$TARGET_EPOCH" ]; then
      TARGET_EPOCH="$P_EPOCH"
      TARGET_WS=$(basename "$f" .json)
    fi
  done

  if [ -n "$TARGET_WS" ]; then
    rebind_terminal "$TRACKING" "$TARGET_WS"
    # Bump the rebound workstream so it stays the freshest match next time, and
    # move the session_id stamp onto it. Any path that rebinds a terminal MUST
    # re-stamp session_id: session-start's terminal-HIT cross-check diverts to
    # whichever ws authoritatively holds the live session_id, so leaving the
    # stamp on the previous ws would silently revert this deliberate switch.
    TGT_FILE="$TRACKING/workstreams/${TARGET_WS}.json"
    TMP=$(mktemp -p "$(dirname "$TGT_FILE")")
    exec 9>"${TGT_FILE}.lock"
    flock 9
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SESSION_ID" '.updated_at = $ts | .session_id = $sid' "$TGT_FILE" > "$TMP" && mv "$TMP" "$TGT_FILE"
    flock -u 9
    exec 9>&-
  else
    # No workstream owns this name yet → claim it for the bound workstream
    # (no suffix; a bare project mention just names the current work).
    _pd_relabel "$MATCHED_PROJECT"
  fi
fi

# Invalidate tab title cache (skip when TID unset to avoid deleting literal /tmp/claude-tab-title-)
if [ -n "${CLAUDE_TERMINAL_ID:-}" ]; then
  rm -f "/tmp/claude-tab-title-${CLAUDE_TERMINAL_ID}"
fi

exit 0
