#!/bin/bash
# PostToolUse hook (matcher: Write|Edit|MultiEdit). When Claude writes a
# progress-*.md file (anywhere under BATON_PROGRESS_DIR; resolved by
# checkpoint_progress_dir() in lib/workstream-lib.sh) with a checkpoint
# PENDING, atomically updates workstreams/<ws>.json (progress_file +
# updated_at), archives the old per-terminal progress files listed at
# PreToolUse time, and sets DONE to block any further tool calls. The
# write itself is the only signal - no separate commit or pointer edit
# is required.
set -u

input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.cwd')
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // "unknown"')
FILE_PATH=$(echo "$input" | jq -r '.tool_input.file_path // empty')
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/workstream-lib.sh"
source "$SCRIPT_DIR/lib/envelope.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/template-resolve.sh"   # tpl::resolve_active_template
source "$SCRIPT_DIR/lib/lints.sh"               # lint::v1/v7/v8
source "$SCRIPT_DIR/lib/rolloff.sh"             # rolloff::dispatch

# Wall-clock start for duration_ms in the envelope.
_WT_START_MS=$(date +%s%3N 2>/dev/null || echo 0)
# BSD date leaves +%3N literal; numeric-guard so the duration arithmetic below
# yields a deterministic 0 instead of garbage on macOS without coreutils.
[[ "$_WT_START_MS" =~ ^[0-9]+$ ]] || _WT_START_MS=0

# Only fire on writes to progress files
[ -z "$FILE_PATH" ] && exit 0
case "$(basename "$FILE_PATH")" in
  progress-*.md) ;;
  *) exit 0 ;;
esac

# Autonomous mode - SDK wrapper handles checkpoints
[ -n "${AGENT_SESSION_ID:-}" ] && exit 0

# Subagent - parent session handles save protocol
AGENT_ID=$(echo "$input" | jq -r '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

# Only fire if a checkpoint is pending
PENDING="/tmp/baton-pending-${SESSION_ID}"
[ -f "$PENDING" ] || exit 0

# Already cleaned up? Guard against re-fire when Claude edits the same file again.
DONE_FLAG="/tmp/baton-done-${SESSION_ID}"
[ -f "$DONE_FLAG" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
TRACKING_DIR="$(checkpoint_dir "$PROJECT_DIR")"

# Resolve written file to an absolute path
case "$FILE_PATH" in
  /*) ABS_FILE="$FILE_PATH" ;;
  *)  ABS_FILE="$CWD/$FILE_PATH" ;;
esac

# v2: workstream comes from terminals/<term_hash>.json (re-read each fire,
# so /resume rebinds take effect immediately).
TH=$(term_hash)
TERM_FILE="$TRACKING_DIR/terminals/${TH}.json"
WORKSTREAM=""
if [ -f "$TERM_FILE" ]; then
  WORKSTREAM=$(jq -r '.workstream // empty' "$TERM_FILE")
fi
WS_DISPLAY=""
if [ -n "$WORKSTREAM" ] && [ -f "$TRACKING_DIR/workstreams/${WORKSTREAM}.json" ]; then
  WS_DISPLAY=$(jq -r '.display_name // empty' "$TRACKING_DIR/workstreams/${WORKSTREAM}.json")
fi
T_FILE=""
POINTER="/tmp/claude-session-tracking-${SESSION_ID}"
[ -f "$POINTER" ] && T_FILE=$(cat "$POINTER")

# Cross-workstream guard: the written basename must start with the
# canonical progress-<workstream>- prefix (or progress-<display_name>-).
# Anchored match - substring would let workstream "main" match
# "progress-mainframe-foo-...md" and clobber the wrong pointer.
# (See commit 96a2e73 for the original incident.)
_BN=$(basename "$FILE_PATH")
_OK=false
if [ -n "$WORKSTREAM" ]; then
  case "$_BN" in
    "progress-${WORKSTREAM}-"* | "progress-${WORKSTREAM}.md") _OK=true ;;
  esac
fi
if [ "$_OK" = false ] && [ -n "$WS_DISPLAY" ]; then
  case "$_BN" in
    "progress-${WS_DISPLAY}-"* | "progress-${WS_DISPLAY}.md") _OK=true ;;
  esac
fi
if [ "$_OK" = false ]; then
  log_event "$PROJECT_DIR" checkpoint basename-reject \
    "session_id=$SESSION_ID" "workstream=$WORKSTREAM" "tracked_dn=$WS_DISPLAY" \
    "basename=$_BN" "cwd=$CWD"
  jq -n --arg bn "$_BN" --arg ws "$WORKSTREAM" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("CHECKPOINT WARNING: Progress file basename \"" + $bn + "\" does not contain current workstream \"" + $ws + "\". Cleanup skipped - rewrite to a path that includes the workstream ID.")
    }
  }'
  exit 0
fi

# Resolve active template + manifest. Single source of truth from template-resolve.sh.
TEMPLATE_PATH="$(tpl::resolve_active_template "$PROJECT_DIR")"
MANIFEST_PATH="${TEMPLATE_PATH%.md}.json"

# Lint pipeline: V8 (cheapest) → V1 → V7. Each lint takes the right arg up-front:
# V1 reads the directive from the template .md file; V7 and V8 read manifest .json.
declare -A LINT_ARG=(
  [lint::v8]="$MANIFEST_PATH"
  [lint::v1]="$TEMPLATE_PATH"
  [lint::v7]="$MANIFEST_PATH"
)
LINT_ERR=""
for lint_fn in lint::v8 lint::v1 lint::v7; do
  if ! err_msg=$($lint_fn "$ABS_FILE" "${LINT_ARG[$lint_fn]}" 2>&1 >/dev/null); then
    LINT_ERR="$err_msg"
    break
  fi
done

if [ -n "$LINT_ERR" ]; then
  log_event "$PROJECT_DIR" checkpoint lint-fail \
    "session_id=$SESSION_ID" "workstream=$WORKSTREAM" "progress=$ABS_FILE"
  jq -n --arg msg "$LINT_ERR" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      permissionDecision: "block",
      additionalContext: ($msg + "\n\nThe progress file write is blocked. Re-write the file with the issue corrected; the lint will re-run on the next write.")
    }
  }'
  exit 0
fi

SAVE_OK=true
if [ -n "$WORKSTREAM" ]; then
  AP="$TRACKING_DIR/workstreams/${WORKSTREAM}.json"
  EXISTING_DN="$WS_DISPLAY"
  [ -z "$EXISTING_DN" ] && EXISTING_DN=$(derive_display_name "$CWD" "$PROJECT_DIR")
  # phase lives in the workstream record, not per-session tracking. Preserve
  # existing value across updates; default to "implementation" only on first write.
  PHASE="implementation"
  [ -f "$AP" ] && PHASE=$(jq -r '.phase // "implementation"' "$AP" 2>/dev/null)
  mkdir -p "$TRACKING_DIR/workstreams"
  # Hold the lock across both jq AND the rename - `flock <file> <cmd>` releases
  # when <cmd> exits, leaving the trailing mv unprotected and racy.
  exec 9>"${AP}.lock"
  flock 9
  if [ -f "$AP" ]; then
    TMP=$(mktemp -p "$(dirname "$AP")")
    if ! { jq --arg p "$ABS_FILE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg dn "$EXISTING_DN" \
        '.progress_file = $p | .updated_at = $ts | .display_name = $dn' \
        "$AP" > "$TMP" && mv "$TMP" "$AP"; }; then
      SAVE_OK=false
      rm -f "$TMP"
    fi
  else
    if ! jq -n --arg ws "$WORKSTREAM" --arg p "$ABS_FILE" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg phase "$PHASE" --arg dn "$EXISTING_DN" \
        '{workstream:$ws, display_name:$dn, progress_file:$p, phase:$phase, updated_at:$ts}' \
        > "$AP"; then
      SAVE_OK=false
    fi
  fi
  flock -u 9
  exec 9>&-
  # Bump terminal_state.updated_at (last-writer-wins, no flock needed)
  if [ "$SAVE_OK" = true ] && [ -f "$TERM_FILE" ]; then
    TMP=$(mktemp -p "$(dirname "$TERM_FILE")")
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated_at = $ts' "$TERM_FILE" > "$TMP" && mv "$TMP" "$TERM_FILE"
  fi
  if [ "$SAVE_OK" = true ]; then
    log_event "$PROJECT_DIR" checkpoint save \
      "session_id=$SESSION_ID" "workstream=$WORKSTREAM" "display_name=$EXISTING_DN" \
      "progress=$ABS_FILE" "cwd=$CWD"
  else
    log_event "$PROJECT_DIR" checkpoint save-failed \
      "session_id=$SESSION_ID" "workstream=$WORKSTREAM" "progress=$ABS_FILE" "cwd=$CWD"
  fi
fi

# Pointer write failed - leave PENDING set so the next progress-file write
# retries cleanup, skip archive (would orphan the old files), and do NOT
# latch DONE (would hard-block the session unrecoverably).
if [ "$SAVE_OK" = false ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "CHECKPOINT WARNING: Failed to update workstream pointer (disk/permission?). State is incomplete and PENDING is still set. Retry by writing the progress file again, or surface the failure to the user."
    }
  }'
  exit 0
fi

# Export prior progress path for rolloff::dispatch (fresh_judgment needs to diff against it).
# ARCHIVE_LIST is written by PreToolUse and holds the prior files most-recent-first.
ARCHIVE_LIST="/tmp/baton-archive-${SESSION_ID}"
ROLLOFF_PRIOR_PROGRESS=""
if [ -f "$ARCHIVE_LIST" ]; then
  ROLLOFF_PRIOR_PROGRESS=$(head -1 "$ARCHIVE_LIST" 2>/dev/null || true)
fi
export ROLLOFF_PRIOR_PROGRESS

# Rolloff: archive-checkbox (task.md) | fresh-judgment (factory.md) | none (free.md).
# Reads strategy + params from the manifest sidecar. No-op on strategy=none.
# previous_l1_epoch persistence lives inside rolloff::dispatch (co-located with the read site).
rolloff::dispatch "$ABS_FILE" "$MANIFEST_PATH" "$WORKSTREAM" "$PROJECT_DIR" 2>/dev/null || true

# Scaffold cleanup: remove the .scaffold.md written by context-checkpoint.sh alongside the
# progress file. Only runs on the lints-passed path (early-return on lint block leaves
# scaffold in place so the model can re-write).
SCAFFOLD_PATH="${ABS_FILE%.md}.scaffold.md"
[ -f "$SCAFFOLD_PATH" ] && rm -f "$SCAFFOLD_PATH"

# Archive old progress files listed at PreToolUse time (skip the one just written)
if [ -f "$ARCHIVE_LIST" ]; then
  ARCHIVE_DIR="$(archive_dir)/progress/$(date +%Y-%m)"
  mkdir -p "$ARCHIVE_DIR"
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ "$(readlink -f "$f")" = "$(readlink -f "$ABS_FILE")" ] && continue
    BASE=$(basename "$f" .md)
    mv "$f" "$ARCHIVE_DIR/${BASE}-${TIMESTAMP}.md" 2>/dev/null
  done < "$ARCHIVE_LIST"
  rm -f "$ARCHIVE_LIST"
fi

# Terminal state: clear PENDING, set DONE
rm -f "$PENDING"
touch "$DONE_FLAG"

# Emit PostToolUse envelope (CC2). Failures go to stderr, never alter the exit code.
{
  _WT_END_MS=$(date +%s%3N 2>/dev/null || echo 0)
  [[ "$_WT_END_MS" =~ ^[0-9]+$ ]] || _WT_END_MS=0
  _WT_DUR=$((_WT_END_MS - _WT_START_MS))
  [ "$_WT_DUR" -lt 0 ] && _WT_DUR=0
  _WT_BASENAME=$(basename "$FILE_PATH" 2>/dev/null || echo "")
  _WT_DATA=$(jq -cn \
    --arg tn "$TOOL_NAME" \
    --arg ws "${WORKSTREAM:-}" \
    --arg th "$TH" \
    --arg bn "$_WT_BASENAME" \
    --argjson dur "$_WT_DUR" \
    '{tool_name:$tn, workstream:$ws, terminal_hash:$th, progress_file_basename:$bn, duration_ms:$dur}' 2>/dev/null) || _WT_DATA='{}'
  envelope::emit "PostToolUse" "$_WT_DATA" 2>/dev/null || true
} || true

PCT=$(cat "/tmp/claude-context-pct-${SESSION_ID}" 2>/dev/null || echo "")
jq -n --arg pct "$PCT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "Checkpoint save complete. Active pointer updated, old progress files archived. Tell the user: \"Context at " + $pct + "%. Progress saved. Please /clear to continue.\" Do NOT take any further actions - subsequent tool calls will be blocked."
  }
}'
