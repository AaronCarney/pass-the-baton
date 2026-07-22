#!/bin/bash
# PreToolUse hook. At the configured threshold (default 20% context fill), marks the session as PENDING,
# lists this terminal's old progress files for archival, and injects the
# save-progress workflow into Claude's next turn. Once the post-write
# trigger sets DONE, blocks all further tool calls until /clear.
# Subagents get a single "wrap up" warning and then a hard block.
# Autonomous mode (AGENT_SESSION_ID set): no-op - the SDK wrapper owns checkpoints.
set -u

input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.cwd')
TOOL_NAME=$(echo "$input" | jq -r '.tool_name // "unknown"')
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/workstream-lib.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/envelope.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/template-resolve.sh"   # tpl::resolve_active_template
source "$SCRIPT_DIR/lib/template-render.sh"    # tpl::render_progress_file

# Single threshold source (E-B): the gate comparisons AND the telemetry field
# below both read this one value, so the trigger and the reported `threshold`
# can never diverge. checkpoint_threshold (workstream-lib.sh) is bounds-validated;
# the inline guard keeps the hook safe if the helper is unavailable.
CC_THRESHOLD=$(checkpoint_threshold 2>/dev/null || echo "${BATON_DEFAULT_PCT_THRESHOLD:-20}")
[[ "$CC_THRESHOLD" =~ ^[0-9]+$ ]] || CC_THRESHOLD="${BATON_DEFAULT_PCT_THRESHOLD:-20}"

: "${_HEALTH_WARN_TOOL_CALLS:=20}"   # warn if no context-pct after N tool calls
# Re-assert N times before hard-denying an interrupted-but-owed checkpoint. Must
# be slower than the health warning (this fires every call while a checkpoint is
# owed) yet fast enough the session cannot run far past threshold unsaved: 3 gives
# the model two soft reminders - enough to recover from a single interrupted turn -
# before removing the option. 1 would deny on the first stray call after any
# interruption; a large value reproduces the silent-drift failure this closes.
: "${_CC_NAG_LIMIT:=3}"              # re-assert N times before hard-denying

# Emit PreToolUse envelope exactly once (CC2). Trap on EXIT to cover every
# early-return path. Failures go to stderr, never alter the hook exit code.
_CC_PCT=""
_CC_PENDING="false"
_CC_EMITTED=0
_emit_cc() {
  [ "$_CC_EMITTED" = "1" ] && return 0
  _CC_EMITTED=1
  local _pct_num="${_CC_PCT:-0}"
  [[ "$_pct_num" =~ ^[0-9]+$ ]] || _pct_num=0
  local _thr="$CC_THRESHOLD"
  local _data
  _data=$(jq -cn --arg tn "$TOOL_NAME" --argjson pct "$_pct_num" --argjson thr "$_thr" --argjson ps "$_CC_PENDING" \
    '{tool_name:$tn, context_pct:$pct, threshold:$thr, pending_set:$ps}' 2>/dev/null) || _data='{}'
  envelope::emit "PreToolUse" "$_data" 2>/dev/null || true
}
trap _emit_cc EXIT

# Autonomous mode → exit immediately
[ -n "${AGENT_SESSION_ID:-}" ] && exit 0

# Subagent detection - Agent tool subagents get agent_id in hook input
AGENT_ID=$(echo "$input" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
  TERM_HASH=$(term_hash)
  PARENT_SID=$(cat "/tmp/claude-parent-sid-${TERM_HASH}" 2>/dev/null)
  [ -z "$PARENT_SID" ] && exit 0
  [[ "$PARENT_SID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

  PCT=$(cat "/tmp/claude-context-pct-${PARENT_SID}" 2>/dev/null)
  [ -z "$PCT" ] && exit 0
  # Treat non-integer PCT (e.g. "30.5", whitespace) as "no value" - bare
  # `[ "$PCT" -lt "$CC_THRESHOLD" ]` errors on those and would fall through to trigger.
  [[ "$PCT" =~ ^[0-9]+$ ]] || exit 0
  [ "$PCT" -lt "$CC_THRESHOLD" ] && exit 0

  # Parent checkpoint already done - block subagent
  if [ -f "/tmp/baton-done-${PARENT_SID}" ]; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Parent session checkpoint complete. Return your results immediately - no further tool calls allowed.",
        additionalContext: "Parent session checkpoint complete. Return your results immediately - no further tool calls allowed."
      }
    }'
    exit 0
  fi

  # One-shot warning per subagent session
  FLAG="/tmp/claude-subagent-checkpoint-${SESSION_ID}"
  [ -f "$FLAG" ] && exit 0
  touch "$FLAG"

  jq -n --arg pct "$PCT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: ("CHECKPOINT - Parent context at " + $pct + "%. Finish your current task concisely and return results to the parent session. Do NOT start new investigations or expand scope.")
    }
  }'
  exit 0
fi

# E8-T7: tools_changed begin
# Stub-active design: activates only when tool_input.tools is present in stdin.
# Production PreToolUse payloads do not include a tools array, so this block is
# a documented no-op in production. Tests fixture tool_input.tools to verify
# the implementation is correct.
_T7_TOOLS_FLAG="/tmp/claude-tools-checked-${SESSION_ID}"
if [ ! -f "$_T7_TOOLS_FLAG" ]; then
  _T7_TOOLS_RAW=$(printf '%s' "$input" | jq -r '.tool_input.tools // empty' 2>/dev/null)
  _T7_TOOLS_TYPE=$(printf '%s' "$input" | jq -r '.tool_input.tools | type' 2>/dev/null)
  if [ "$_T7_TOOLS_TYPE" = "array" ]; then
    touch "$_T7_TOOLS_FLAG"
    _T7_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
    _T7_STATE_FILE="$_T7_STATE_DIR/tools-hash-state.json"
    mkdir -p "$_T7_STATE_DIR"
    # Canonicalise then hash
    _T7_CURRENT_HASH=$(printf '%s' "$input" | jq -r '.tool_input.tools' | jq -cS '.' | sha256sum | awk '{print $1}')
    _T7_PRIOR_HASH=$(jq -r '.last_tools_sha256 // empty' "$_T7_STATE_FILE" 2>/dev/null)
    if [ -n "$_T7_PRIOR_HASH" ] && [ "$_T7_PRIOR_HASH" != "$_T7_CURRENT_HASH" ]; then
      _t7_data=$(jq -cn \
        --arg prior  "$_T7_PRIOR_HASH" \
        --arg current "$_T7_CURRENT_HASH" \
        --arg sid    "$SESSION_ID" \
        '{prior_hash:$prior, current_hash:$current, session_id:$sid}') || _t7_data='{}'
      envelope::emit "tools_changed" "$_t7_data" 2>/dev/null || true
    fi
    # Write current hash to state file under flock
    _T7_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    (
      flock 9
      jq -cn --arg h "$_T7_CURRENT_HASH" --arg ts "$_T7_NOW" \
        '{last_tools_sha256:$h, last_seen_at:$ts}' > "${_T7_STATE_FILE}.tmp" \
        && mv "${_T7_STATE_FILE}.tmp" "$_T7_STATE_FILE"
      chmod 0600 "$_T7_STATE_FILE" 2>/dev/null || true
    ) 9>"${_T7_STATE_FILE}.lock"
  fi
fi
# E8-T7: tools_changed end

# Manual early checkpoint (/pass-the-baton:renew). A per-session force flag makes the
# checkpoint fire regardless of the reported context %, running the SAME path as a
# threshold crossing. Consumed here so one /renew arms exactly one checkpoint.
FORCE_FLAG="/tmp/baton-force-checkpoint-${SESSION_ID}"
_CC_FORCE=""
if [ -f "$FORCE_FLAG" ]; then _CC_FORCE=1; rm -f "$FORCE_FLAG"; fi

PCT=$(cat "/tmp/claude-context-pct-${SESSION_ID}" 2>/dev/null)
_CC_PCT="$PCT"

# Absent AND malformed both mean "no usable value". Previously only the absent
# case reached the health counter; a malformed value (e.g. "20.5", "20%", "20 ")
# bailed at the integer guard with no counter, no warning and no log - silently
# disabling checkpointing for the whole session. Nothing in this repo writes
# /tmp/claude-context-pct-*; it is authored by the user's own statusline, so a
# malformed value is an expected input, not a defensive hypothetical.
_CC_PCT_BAD=""
if [ -z "$PCT" ]; then
  _CC_PCT_BAD="absent"
elif ! [[ "$PCT" =~ ^[0-9]+$ ]]; then
  _CC_PCT_BAD="malformed"
fi
if [ -z "$_CC_FORCE" ] && [ -n "$_CC_PCT_BAD" ]; then
  COUNT_FILE="/tmp/baton-health-${SESSION_ID}"
  COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$COUNT_FILE"
  WARNED="/tmp/baton-warned-${SESSION_ID}"
  if [ "$COUNT" -ge "$_HEALTH_WARN_TOOL_CALLS" ] && [ ! -f "$WARNED" ]; then
    touch "$WARNED"
    _CC_WARN_DETAIL="Context percentage not available after ${_HEALTH_WARN_TOOL_CALLS}+ tool calls."
    if [ "$_CC_PCT_BAD" = "malformed" ]; then
      _CC_WARN_DETAIL="Context percentage is not an integer (got \"${PCT}\") after ${_HEALTH_WARN_TOOL_CALLS}+ tool calls."
    fi
    jq -n --arg detail "$_CC_WARN_DETAIL" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        additionalContext: ("WARNING: " + $detail + " The statusline may not be configured to emit a plain integer. Checkpoint auto-save will not trigger. Consider a manual checkpoint if this session is long.")
      }
    }'
    exit 0
  fi
  exit 0
fi
# Forced with no usable % - synthesize a valid number for the comparisons/logs below.
if [ -n "$_CC_FORCE" ] && ! [[ "$PCT" =~ ^[0-9]+$ ]]; then PCT="$CC_THRESHOLD"; fi
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
FLAG="/tmp/claude-context-triggered-${SESSION_ID}"
DONE="/tmp/baton-done-${SESSION_ID}"

# The DONE guard and the nag re-assert run BEFORE the threshold early-exit below, so a
# checkpoint that is owed (FLAG set + PENDING) or done (DONE) keeps being enforced even if the
# reported context % dips back under the threshold - the earlier placement let such a session
# stop being nagged with a save still owed. A fresh call with FLAG unset falls through both
# blocks to the threshold exit, so a below-threshold session with nothing owed triggers nothing.

# If checkpoint save already completed, block further work
if [ -f "$DONE" ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Checkpoint complete. Do NOT continue working. Tell the user to /clear to start a fresh session.",
      additionalContext: "Checkpoint complete. Do NOT continue working. Tell the user to /clear to start a fresh session."
    }
  }'
  exit 0
fi

# A one-shot with no backstop was the last silent path in the lifecycle. If the
# checkpoint turn is interrupted (ESC, a text-only reply, or a Bash call, which
# this hook permits), no progress file is ever written, yet FLAG suppressed every
# later fire - PENDING stayed set forever, DONE never latched so the guard above
# never engaged, and the session ran to auto-compaction unsaved with no record.
# Re-assert while the checkpoint is still owed, escalating to a hard deny.
if [ -f "$FLAG" ]; then
  [ -f "/tmp/baton-pending-${SESSION_ID}" ] || exit 0
  # NEVER impede the one write that clears PENDING. The re-assert below escalates
  # to a hard deny, but this is a PreToolUse hook - it fires BEFORE the tool runs,
  # and PENDING is cleared only by checkpoint-write-trigger's PostToolUse AFTER a
  # progress-*.md Write completes. Without this exemption the deny would block the
  # progress-file write itself, deadlocking the very checkpoint the nag demands -
  # re-creating the silent-loss class this whole change closes. So let a Write/Edit
  # to a progress-*.md path through untouched (do not even count it as a nag).
  _CC_FP=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  case "${TOOL_NAME}:$(basename -- "${_CC_FP:-x}")" in
    Write:progress-*.md|Edit:progress-*.md|MultiEdit:progress-*.md) exit 0 ;;
  esac
  NAG_FILE="/tmp/baton-nag-${SESSION_ID}"
  NAG=$(cat "$NAG_FILE" 2>/dev/null || echo 0)
  [[ "$NAG" =~ ^[0-9]+$ ]] || NAG=0
  NAG=$((NAG + 1))
  echo "$NAG" > "$NAG_FILE"
  log_event "$PROJECT_DIR" checkpoint pending-unsatisfied \
    "session_id=$SESSION_ID" "attempt=$NAG" 2>/dev/null || true
  if [ "$NAG" -ge "${_CC_NAG_LIMIT:-3}" ]; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "CHECKPOINT STILL UNSAVED. The progress file was never written, so this session cannot be handed off. Write it now to the path given in the checkpoint instruction. Do NOT tell the user to /clear."
      }
    }'
  else
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: "CHECKPOINT STILL PENDING - the progress file has not been written yet. Stop other work and write it before continuing. If subagents are still running, let them return and fold their results into the checkpoint first, so nothing in flight is lost."
      }
    }'
  fi
  exit 0
fi

# Below the threshold with no checkpoint owed (FLAG unset): nothing to do on this call.
[ -z "$_CC_FORCE" ] && [ "$PCT" -lt "$CC_THRESHOLD" ] && exit 0
touch "$FLAG"

TRACKING_DIR="$(checkpoint_dir "$PROJECT_DIR")"
SESSIONS_DIR="$(checkpoint_progress_dir "$PROJECT_DIR")"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Find workstream - terminals/<term_hash>.json is the v2 source of truth (re-read
# each fire so a resume/rebind takes effect immediately). POINTER → T_FILE is the
# v1 fallback for sessions whose terminal record hasn't been populated yet.
TERM_HASH=$(term_hash)
TERM_FILE="$TRACKING_DIR/terminals/${TERM_HASH}.json"
WORKSTREAM=""
if [ -f "$TERM_FILE" ]; then
  WORKSTREAM=$(jq -r '.workstream // empty' "$TERM_FILE")
fi

POINTER="/tmp/claude-session-tracking-${SESSION_ID}"
T_FILE=""
if [ -f "$POINTER" ]; then
  T_FILE=$(cat "$POINTER")
  if [ -f "$T_FILE" ]; then
    # v1 fallback: only use T_FILE's workstream when terminals/<hash>.json didn't resolve.
    if [ -z "$WORKSTREAM" ]; then
      WORKSTREAM=$(jq -r '.workstream // empty' "$T_FILE")
    fi
    # Mark progress as pending (side-effect preserved regardless of resolution path)
    exec 9>"${T_FILE}.lock"
    flock 9
    jq '.progress_file = "pending"' "$T_FILE" > "${T_FILE}.tmp" \
      && mv "${T_FILE}.tmp" "$T_FILE"
    flock -u 9
    exec 9>&-
  fi
fi

# Whitelist before use: both reads above take WORKSTREAM from an on-disk JSON
# record, and it becomes a path component below. Blanking is safe here - the
# recovery ladder immediately below reacquires or mints.
case "$WORKSTREAM" in
  *[!A-Za-z0-9._-]*) WORKSTREAM="" ;;
esac

# Recovery ladder. The WRITE path used to consult ONLY terminals/<hash>.json; when
# that missed, the checkpoint went to progress-unassociated-*.md, the PostToolUse
# guard rejected it, and the handoff was lost silently. Rung 1: reacquire by
# session_id and rebind this terminal. Rung 2: mint. After this block WORKSTREAM is
# always non-empty, so there is no unassociated write path left.
if [ -z "$WORKSTREAM" ]; then
  WORKSTREAM=$(find_workstream_by_session_id "$TRACKING_DIR" "$SESSION_ID" 2>/dev/null || true)
  case "$WORKSTREAM" in
    *[!A-Za-z0-9._-]*) WORKSTREAM="" ;;
  esac
  if [ -n "$WORKSTREAM" ]; then
    rebind_terminal "$TRACKING_DIR" "$WORKSTREAM"
    log_event "$PROJECT_DIR" checkpoint reacquire-by-session-id \
      "workstream=$WORKSTREAM" "session_id=$SESSION_ID" 2>/dev/null || true
  fi
fi
if [ -z "$WORKSTREAM" ]; then
  # Nothing to reacquire - mint, so the checkpoint always has a real home.
  # Naming follows session-start's shape: <branch-slug>-<stamp>-<hash6>.
  #
  # The branch read is NOT session-start's one-liner, deliberately - see the note
  # below. Assign first, test the exit status separately, then whitelist the value.
  _CC_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || _CC_BRANCH=""
  case "$_CC_BRANCH" in
    ""|HEAD|*[!A-Za-z0-9._/-]*) _CC_BRANCH="main" ;;
  esac
  _CC_BRANCH_SLUG=$(echo "$_CC_BRANCH" | sed 's|/|-|g')
  WORKSTREAM="${_CC_BRANCH_SLUG}-$(date +%Y%m%d-%H%M%S)-${TERM_HASH:0:6}"
  _CC_DISPLAY=$(derive_display_name "$CWD" "$PROJECT_DIR" "$WORKSTREAM")
  _CC_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$TRACKING_DIR/workstreams"
  # Track whether the mint actually landed. A read-only or full .baton makes the
  # record write or the rebind fail; logging mint-workstream unconditionally would
  # record a mint that never happened, and the log is the one artifact an operator
  # consults. The downstream PostToolUse block still catches the failure - this
  # only makes it observable at the point it occurs.
  _CC_MINT_OK=1
  jq -n --arg ws "$WORKSTREAM" --arg dn "$_CC_DISPLAY" --arg ts "$_CC_NOW" \
        --arg pd "$CWD" --arg sid "$SESSION_ID" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown",
      updated_at:$ts, project_dir:$pd, session_id:$sid}' \
    | atomic_write "$TRACKING_DIR/workstreams/${WORKSTREAM}.json" || _CC_MINT_OK=0
  rebind_terminal "$TRACKING_DIR" "$WORKSTREAM" || _CC_MINT_OK=0
  if [ "$_CC_MINT_OK" = 1 ]; then
    log_event "$PROJECT_DIR" checkpoint mint-workstream \
      "workstream=$WORKSTREAM" "session_id=$SESSION_ID" 2>/dev/null || true
  else
    log_event "$PROJECT_DIR" checkpoint mint-failed \
      "workstream=$WORKSTREAM" "session_id=$SESSION_ID" 2>/dev/null || true
  fi
fi

# Mark progress files for archival - actual move deferred to checkpoint-write-trigger
# so the pointer stays valid until the new file is written.
# Only archive THIS terminal's files (by hash) to avoid cross-terminal collision.
for f in "$SESSIONS_DIR"/progress-*.md; do
  [ -f "$f" ] || continue
  BASE=$(basename "$f" .md)
  if [ -n "$WORKSTREAM" ]; then
    if echo "$BASE" | grep -qF "$TERM_HASH"; then
      : # This terminal's file - archive it
    elif echo "$BASE" | grep -qF "$WORKSTREAM" && ! echo "$BASE" | grep -qE '[a-f0-9]{6}$'; then
      : # Legacy file (no hash suffix) matching workstream - archive it
    else
      continue
    fi
  fi
  echo "$f" >> "/tmp/baton-archive-${SESSION_ID}"
done

# Set pending marker for write-trigger hook to detect
echo "$PCT" > "/tmp/baton-pending-${SESSION_ID}"
_CC_PENDING="true"
# Parent-sid map mtime refresh (durable fix for the dashboard fail-open documented in
# baton-dashboard.sh): the guard keys on /tmp/claude-parent-sid-<term_hash>, whose mtime was
# pinned at session start and swept by the /tmp TTL, so a long single session could lose its
# map while a live flag remains. Touch it here, on the checkpoint WRITE path, so the map
# outlives the session. TERM_HASH is already resolved above.
[ -n "$TERM_HASH" ] && touch "/tmp/claude-parent-sid-${TERM_HASH}" 2>/dev/null || true
# The trigger itself must be observable. Without this, hook-events.jsonl cannot
# distinguish "never triggered" from "triggered and silently dropped" - only the
# reacquire/mint branches logged, so an ordinary successful trigger left no trace.
log_event "$PROJECT_DIR" checkpoint triggered \
  "pct=$PCT" "workstream=$WORKSTREAM" "session_id=$SESSION_ID" 2>/dev/null || true

# Compute the exact absolute path Claude should write to, and resolve active template.
# Path is per-terminal scoped (TERM_HASH) to avoid cross-terminal collision.
TEMPLATE_PATH="$(tpl::resolve_active_template "$PROJECT_DIR")"
# WORKSTREAM is guaranteed non-empty by the recovery ladder above.
PROGRESS_PATH="$(checkpoint_progress_dir "$PROJECT_DIR")/progress-${WORKSTREAM}-${TERM_HASH}.md"

# Locate most recent prior progress file for this workstream - drives the
# <<ARCHIVED_CHECKBOXES>> carry-forward in tpl::render_progress_file. Looks first
# at the active progress directory, then at the archive (the prior session's
# write-trigger may have already moved the most recent file).
_find_prior_progress() {
  local ws="$1" project_dir="$2"
  # active_dir was hardcoded to "$tracking_dir/progress", diverging from
  # checkpoint_progress_dir() (which honours BATON_PROGRESS_DIR) used everywhere
  # else in this hook; archive_dir pointed at "$tracking_dir/archive/progress",
  # which has NO writer at all - the only progress archiver writes to
  # $(archive_dir)/progress/<YYYY-MM>. Both misses silently blanked
  # <<ARCHIVED_CHECKBOXES>>, and V8 stayed satisfied because the token WAS
  # substituted. The scaffold exclusion matters because the leftover
  # .scaffold.md matches this glob and is necessarily newer than the real file.
  # NOTE: the local is archive_ROOT, not archive_dir. `archive_dir` is a
  # FUNCTION in workstream-lib.sh; a local of that name shadows it and the
  # command substitution below would recurse into the variable instead of
  # calling the helper. The old code got away with the name only because it
  # never called the function.
  local active_dir archive_root newest=""
  active_dir="$(checkpoint_progress_dir "$project_dir")"
  archive_root="$(archive_dir)/progress"
  newest=$(ls -t "$active_dir"/progress-"$ws"-*.md 2>/dev/null | grep -v '\.scaffold\.md$' | head -1)
  if [ -z "$newest" ]; then
    newest=$(find "$archive_root" -name "progress-${ws}-*.md" -type f 2>/dev/null \
      | grep -v '\.scaffold\.md$' | xargs -r ls -t 2>/dev/null | head -1)
  fi
  printf '%s' "$newest"
}
ROLLOFF_PRIOR_PROGRESS="$(_find_prior_progress "$WORKSTREAM" "$PROJECT_DIR")"
export ROLLOFF_PRIOR_PROGRESS

# Render the HOOK-FILLED placeholders into a scaffold the model can fill in.
# tpl::render_progress_file reads ROLLOFF_PRIOR_PROGRESS to substitute
# <<ARCHIVED_CHECKBOXES>> from the prior file's ## Archived body.
SCAFFOLD_PATH="${PROGRESS_PATH%.md}.scaffold.md"
tpl::render_progress_file "$TEMPLATE_PATH" "$WORKSTREAM" "$PROJECT_DIR" > "$SCAFFOLD_PATH" 2>/dev/null || cp "$TEMPLATE_PATH" "$SCAFFOLD_PATH"

# Extract the literal Session Directive block from the active template for V2 re-injection.
DIRECTIVE_BLOCK=$(awk '/^## Session Directive$/{flag=1; next} /^## /{flag=0} flag' "$TEMPLATE_PATH" 2>/dev/null || echo "")

jq -n --arg pct "$PCT" --arg progress "$PROGRESS_PATH" --arg template "$TEMPLATE_PATH" --arg scaffold "$SCAFFOLD_PATH" --arg ws "${WORKSTREAM:-<none>}" --arg directive "$DIRECTIVE_BLOCK" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    additionalContext: (
      "CHECKPOINT TRIGGERED - Context at " + $pct + "%. Stop all investigation and new work NOW. Your only next action is to save session state.\n\n" +
      "Workflow (execute in order):\n\n" +
      "1. If you have uncommitted changes in flight, commit them first with their own descriptive message. Otherwise skip.\n\n" +
      "2. Read " + $template + " - the active progress-file template (defines section structure + literal Session Directive).\n   A pre-rendered scaffold with HOOK-FILLED placeholders already substituted is at:\n   " + $scaffold + "\n   Read the scaffold as a reference. Compose the final progress file from it and write the result to the path in step 3. Do NOT edit the scaffold file in place. You only need to fill the MODEL-AUTHORED placeholders (<<WHATS_NEXT>>, <<APPLICATION_CONTEXT>>, <<CONSTRAINTS_BLOCKERS>>, and the Task State payload if present).\n\n" +
      "3. Write the progress file to EXACTLY this path:\n   " + $progress + "\n   The basename must contain the workstream id \"" + $ws + "\" or the cross-workstream guard will reject the write.\n\n" +
      "4. The write triggers the lint pipeline (V1 directive verbatim, V7 structural, V8 placeholder-survivor). On lint failure the write is blocked with a retry message; fix and re-write.\n\n" +
      "5. Tell the user: \"Context at " + $pct + "%. Progress saved. Please /clear to continue.\"\n\n" +
      "After step 5, STOP. Any further tool calls will be blocked by the DONE guard.\n\n" +
      "--- Session Directive (verbatim from active template; V1 line-diff will validate your copy) ---\n" +
      $directive
    )
  }
}'
