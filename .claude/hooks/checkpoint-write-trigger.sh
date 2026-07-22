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

# E6: source the shared config resolver + the auto-continue driver selector.
# Self-contained: guard-source lib/config.sh; if unreachable, define FAITHFUL inline
# fallbacks so a dashboard config.json write is still honored under plugin
# distribution. Precedent: session-start.sh:23-32. The fallback MUST match
# lib/config.sh's precedence exactly - a drift here is a silent behavior fork.
# --- BEGIN cfg-guard ---
if ! declare -F _cfg::auto_continue_mode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/config.sh" 2>/dev/null || true
fi
if ! declare -F _cfg::get >/dev/null 2>&1; then
  _cfg::get() {
    local v; v="${!1:-}"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json"
    local ck="${3:-$1}"
    if [ -f "$cfg" ]; then
      v="$(jq -r --arg k "$ck" '.[$k] // empty' "$cfg" 2>/dev/null || true)"
      if [ -n "$v" ] && [ "$v" != 'null' ]; then printf '%s' "$v"; return 0; fi
    fi
    printf '%s' "${2:-}"
  }
fi
if ! declare -F _cfg::auto_continue_mode >/dev/null 2>&1; then
  : "${BATON_DEFAULT_AUTO_CONTINUE_MODE:=off}"
  _cfg::auto_continue_mode() {
    local m legacy_default="$BATON_DEFAULT_AUTO_CONTINUE_MODE"
    [ "${BATON_AUTO_CONTINUE:-0}" = "1" ] && legacy_default=tmux
    m=$(_cfg::get BATON_AUTO_CONTINUE_MODE "$legacy_default" auto_continue_mode)
    case "$m" in
      tmux|relaunch|off) printf '%s' "$m" ;;
      *) printf '%s' "$BATON_DEFAULT_AUTO_CONTINUE_MODE" ;;
    esac
  }
fi
# --- END cfg-guard ---

# Wall-clock start for duration_ms in the envelope.
_WT_START_MS=$(date +%s%3N 2>/dev/null || echo 0)
# BSD date leaves +%3N literal; numeric-guard so the duration arithmetic below
# yields a deterministic 0 instead of garbage on macOS without coreutils.
[[ "$_WT_START_MS" =~ ^[0-9]+$ ]] || _WT_START_MS=0

# Only fire on writes to progress files
[ -z "$FILE_PATH" ] && exit 0
case "$(basename "$FILE_PATH")" in
  *.scaffold.md) exit 0 ;;
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
# so a resume/rebind takes effect immediately).
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
# Reacquire by session_id when the terminal binding did not resolve, so both
# halves of a checkpoint agree on the workstream. Reached only on a binding miss.
if [ -z "$WORKSTREAM" ]; then
  WORKSTREAM=$(find_workstream_by_session_id "$TRACKING_DIR" "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$WORKSTREAM" ]; then
    rebind_terminal "$TRACKING_DIR" "$WORKSTREAM"
    log_event "$PROJECT_DIR" checkpoint reacquire-by-session-id \
      "session_id=$SESSION_ID" "workstream=$WORKSTREAM" 2>/dev/null || true
    if [ -f "$TRACKING_DIR/workstreams/${WORKSTREAM}.json" ]; then
      WS_DISPLAY=$(jq -r '.display_name // empty' "$TRACKING_DIR/workstreams/${WORKSTREAM}.json")
    fi
  fi
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
  # Top-level decision/reason - the documented PostToolUse blocking shape.
  # hookSpecificOutput.permissionDecision does NOT exist for PostToolUse and is
  # silently stripped, which is why the previous warning here never blocked.
  # PENDING stays set and DONE is never written, so the save is still owed.
  if [ -n "$WORKSTREAM" ]; then
    _WANT="progress-${WORKSTREAM}-$(term_hash).md"
    jq -n --arg bn "$_BN" --arg want "$_WANT" '{
      decision: "block",
      reason: ("CHECKPOINT NOT SAVED. The progress file was written to \"" + $bn + "\", which does not belong to the current workstream, so it was not registered as a handoff. Re-write the SAME content to \"" + $want + "\" in the progress directory. Do NOT tell the user to /clear until that write succeeds.")
    }'
  else
    jq -n --arg bn "$_BN" '{
      decision: "block",
      reason: ("CHECKPOINT SAVE FAILED. No workstream could be resolved for this session, so \"" + $bn + "\" was not registered as a handoff. Do NOT tell the user to /clear - the session state is unsaved and clearing now loses it. Report the failure to the user instead.")
    }'
  fi
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
    decision: "block",
    reason: ($msg + "\n\nThe progress file failed validation and was NOT registered as a handoff. Re-write the file with the issue corrected; the lint re-runs on the next write. Do NOT tell the user to /clear until it passes.")
  }'
  exit 0
fi

SAVE_OK=true
# Invariant: past the cross-workstream guard, WORKSTREAM is non-empty. Enforce it
# rather than assuming it - everything below (pointer save, PENDING clear, DONE
# latch) is only correct under it, and the DONE latch is not itself guarded.
if [ -z "$WORKSTREAM" ]; then
  log_event "$PROJECT_DIR" checkpoint invariant-no-workstream \
    "session_id=$SESSION_ID" "basename=$_BN" "cwd=$CWD"
  jq -n --arg bn "$_BN" '{
    decision: "block",
    reason: ("CHECKPOINT SAVE FAILED. No workstream could be resolved for this session, so \"" + $bn + "\" was not registered as a handoff. Do NOT tell the user to /clear - the session state is unsaved and clearing now loses it. Report the failure to the user instead.")
  }'
  exit 0
fi
if [ -n "$WORKSTREAM" ]; then
  AP="$TRACKING_DIR/workstreams/${WORKSTREAM}.json"
  EXISTING_DN="$WS_DISPLAY"
  [ -z "$EXISTING_DN" ] && EXISTING_DN=$(derive_display_name "$CWD" "$PROJECT_DIR" "$WORKSTREAM")
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
    if ! { jq --arg p "$ABS_FILE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg dn "$EXISTING_DN" --arg sid "$SESSION_ID" \
        '.progress_file = $p | .updated_at = $ts | .display_name = $dn | .session_id = $sid' \
        "$AP" > "$TMP" && mv "$TMP" "$AP"; }; then
      SAVE_OK=false
      rm -f "$TMP"
    fi
  else
    if ! jq -n --arg ws "$WORKSTREAM" --arg p "$ABS_FILE" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg phase "$PHASE" --arg dn "$EXISTING_DN" --arg sid "$SESSION_ID" \
        '{workstream:$ws, display_name:$dn, progress_file:$p, phase:$phase, updated_at:$ts, session_id:$sid}' \
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
  # This is the path where the pointer write ACTUALLY failed, i.e. the handoff is
  # genuinely lost - strictly worse than basename-reject, which does block. It
  # previously emitted advisory additionalContext only, which PostToolUse strips,
  # so the tool result read as success and the model went on to tell the user to
  # /clear. Downstream the workstream record still points at the PREVIOUS
  # session's progress_file, which exists, so resolve_progress_file's primary
  # branch succeeds on the stale path and the handoff silently regresses a session.
  # PENDING stays set and DONE is still never latched - blocking does not change that.
  jq -n '{
    decision: "block",
    reason: "CHECKPOINT NOT SAVED. Updating the workstream pointer failed (disk full or permissions?), so the progress file was not registered as a handoff. Re-write the progress file to retry. Do NOT tell the user to /clear - the session state is unsaved and clearing now loses it."
  }'
  exit 0
fi

# Export prior progress path for rolloff::dispatch (fresh_judgment needs to diff against it).
ARCHIVE_LIST="/tmp/baton-archive-${SESSION_ID}"
# The list is produced by a bash glob, so it arrives in collation order, NOT
# most-recent-first as previously commented. rolloff needs the newest prior file.
# The scaffold exclusion is required, not defensive: the producer's glob matches
# progress-<ws>-<hash>.scaffold.md, and under mtime ordering a leftover scaffold
# outranks the real file whenever it is newer - which is finding B2 again.
ROLLOFF_PRIOR_PROGRESS=""
if [ -f "$ARCHIVE_LIST" ]; then
  ROLLOFF_PRIOR_PROGRESS=$(grep -v '\.scaffold\.md$' "$ARCHIVE_LIST" 2>/dev/null \
    | xargs -r -d '\n' ls -t 2>/dev/null | head -1 || true)
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
    if ! mv "$f" "$ARCHIVE_DIR/${BASE}-${TIMESTAMP}.md" 2>/dev/null; then
      log_event "$PROJECT_DIR" checkpoint archive-failed \
        "session_id=$SESSION_ID" "file=$f" "dest=$ARCHIVE_DIR" 2>/dev/null || true
    fi
  done < "$ARCHIVE_LIST"
  rm -f "$ARCHIVE_LIST"
fi

# Terminal state: clear PENDING, set DONE
rm -f "$PENDING"
touch "$DONE_FLAG"

# E6 same-terminal automation (opt-in, tmux-only). Spawn the detached injector
# that sends /clear + a continue nudge into this pane so the human does not have
# to. Every precondition miss -> clean no-op. Fully detached (setsid + redirected
# fds + disown) so it outlives this hook and never writes to the hook's stdout.
# LOAD-BEARING: this hook fires mid-turn (PostToolUse), so the pane is NON-idle at
# spawn and the injector's first poll-until-idle correctly waits for THIS turn to
# end before sending /clear. Moving the spawn to a Stop/idle hook would make the
# pane already-idle at spawn and fire /clear prematurely - do not relocate it.
if [ "$(_cfg::auto_continue_mode)" = "tmux" ] && [ -n "${TMUX:-}" ]; then
  _AC_PANE=""
  [ -f "$TERM_FILE" ] && _AC_PANE=$(jq -r '.tmux_pane // empty' "$TERM_FILE" 2>/dev/null)
  if [ -n "$_AC_PANE" ]; then
    _AC_BIN="$(_cfg::get BATON_AUTO_CONTINUE_BIN "$SCRIPT_DIR/../../tools/baton-auto-continue.sh")"
    if [ -x "$_AC_BIN" ] || [ -f "$_AC_BIN" ]; then
      # Mirror the setsid/nohup guard at session-start.sh:459 so the injector
      # still detaches on hosts without setsid (e.g. macOS default).
      if command -v setsid >/dev/null 2>&1; then
        setsid bash "$_AC_BIN" "$SESSION_ID" "$DONE_FLAG" "$_AC_PANE" \
          >/dev/null 2>&1 </dev/null &
      else
        nohup bash "$_AC_BIN" "$SESSION_ID" "$DONE_FLAG" "$_AC_PANE" \
          >/dev/null 2>&1 </dev/null &
      fi
      disown 2>/dev/null || true
    fi
  fi
fi

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
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=""
jq -n --arg pct "$PCT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Checkpoint save complete. Active pointer updated, old progress files archived. Tell the user: \"" + (if $pct == "" then "Progress saved." else "Context at " + $pct + "%. Progress saved." end) + " Please /clear to continue.\" Do NOT take any further actions - subsequent tool calls will be blocked.")
  }
}'
