#!/bin/bash
# Shared workstream functions for checkpoint hooks.

# Append a structured JSONL event to the persistent hook audit log.
# Keeps a forensic trail of selection outcomes, warnings, and sticky writes -
# survives WSL shutdowns (unlike /tmp debug log). Gitignored.
# Usage: log_event "$project_dir" "$hook" "$event" [ key=value ... ]
log_event() {
  local project_dir="$1" hook="$2" event="$3"
  shift 3
  local log_file
  log_file="$(checkpoint_dir "$project_dir")/hook-events.jsonl"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  # Pre-create with mode 0600 (subshell-scoped umask) so the first append cannot
  # land at the inherited umask before the trailing chmod runs. Mirrors the
  # envelope::emit pattern at lib/envelope.sh:70-72.
  [ ! -e "$log_file" ] && (umask 0177; : >> "$log_file") 2>/dev/null
  local json
  json=$(jq -cn 2>/dev/null \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hook "$hook" \
    --arg event "$event" \
    --arg term "${CLAUDE_TERMINAL_ID:-}" \
    '{ts:$ts, hook:$hook, event:$event, terminal:$term}')
  [ -z "$json" ] && return 0
  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    json=$(jq -c 2>/dev/null --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$json")
    [ -z "$json" ] && return 0
  done
  echo "$json" >> "$log_file" 2>/dev/null || true
  chmod 0600 "$log_file" 2>/dev/null || true
}

# term_hash - stable per-terminal identifier with deterministic fallbacks.
# Order: CLAUDE_TERMINAL_ID > $(tty) > parent shell's TTY (via $PPID).
# Centralized so all hooks resolve identity identically.
term_hash() {
  local source_val=""
  if [ -n "${CLAUDE_TERMINAL_ID:-}" ]; then
    source_val="$CLAUDE_TERMINAL_ID"
  else
    local t
    t=$(tty 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "not a tty" ]; then
      source_val="$t"
    else
      # Last resort: parent shell's TTY
      source_val=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
    fi
  fi
  echo -n "${USER}:${source_val}" | md5sum | cut -d' ' -f1
}

# term_hash_source - returns which fallback tier resolved (for terminals/<hash>.json terminal_id field).
term_hash_source() {
  if [ -n "${CLAUDE_TERMINAL_ID:-}" ]; then
    echo "$CLAUDE_TERMINAL_ID"
  else
    local t
    t=$(tty 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "not a tty" ]; then
      echo "$t"
    else
      ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' '
    fi
  fi
}

# CC3 helpers - env-var resolution for OSS configurability.
# All readers honor the env var when set; otherwise fall back to a documented default.

checkpoint_threshold() {
  echo "${BATON_PCT_THRESHOLD:-23}"
}

# checkpoint_dir <project_dir> - root for tracking state.
# Default: $project_dir/.baton (CC1).
checkpoint_dir() {
  if [ -n "${BATON_DIR:-}" ]; then
    echo "$BATON_DIR"
  else
    echo "$1/.baton"
  fi
}

# checkpoint_progress_dir <project_dir> - where progress files live.
# Default: $(checkpoint_dir)/progress.
checkpoint_progress_dir() {
  if [ -n "${BATON_PROGRESS_DIR:-}" ]; then
    echo "$BATON_PROGRESS_DIR"
  else
    echo "$(checkpoint_dir "$1")/progress"
  fi
}

# archive_dir - XDG-aligned archive root, no project arg (archives are user-global).
archive_dir() {
  echo "${BATON_ARCHIVE_DIR:-$HOME/.local/share/baton}"
}

# TTL helpers - return seconds (or minutes for /tmp sweep).
workstream_ttl_seconds() {
  local d="${BATON_WORKSTREAM_TTL_DAYS:-30}"
  echo $((d * 86400))
}

tracking_ttl_seconds() {
  local d="${BATON_TRACKING_TTL_DAYS:-7}"
  echo $((d * 86400))
}

tmp_ttl_minutes() {
  local h="${BATON_TMP_TTL_HOURS:-24}"
  echo $((h * 60))
}

# (sticky helpers removed in v2 - see the checkpoint-system design (maintained internally))

# Resolve a progress file to an existing path.
# Falls back to searching by workstream name, then display_name.
# Usage: resolved=$(resolve_progress_file "$latest" "$project_dir" "$workstream" "$display_name")
resolve_progress_file() {
  local latest="$1" project_dir="$2" ws="$3" display="${4:-}"
  local abs_path="" sessions_dir="$project_dir/docs/sessions"

  # Make path absolute
  if [ -n "$latest" ] && [ "$latest" != "null" ]; then
    case "$latest" in
      /*) abs_path="$latest" ;;
      *)  abs_path="$project_dir/$latest" ;;
    esac
  fi

  # Primary: exact path (must be non-empty file)
  if [ -n "$abs_path" ] && [ -s "$abs_path" ]; then
    echo "$abs_path"
    return 0
  fi

  # Build list of dirs to search: BATON_PROGRESS_DIR if set, else $sessions_dir.
  # No symlink-walk. OSS code has no knowledge of projects/ layout.
  local search_dirs=()
  if [ -n "${BATON_PROGRESS_DIR:-}" ]; then
    search_dirs=("$BATON_PROGRESS_DIR")
  else
    search_dirs=("$sessions_dir")
  fi

  # Fallback 1: newest progress file matching workstream name
  if [ -n "$ws" ]; then
    local found=""
    for _dir in "${search_dirs[@]}"; do
      for f in "$_dir"/progress-*.md; do
        [ -s "$f" ] || continue
        case "$(basename "$f")" in
          *"$ws"*) found="$f" ;;
        esac
      done
    done
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  fi

  # Fallback 2: newest progress file matching display_name
  if [ -n "$display" ]; then
    local found=""
    for _dir in "${search_dirs[@]}"; do
      for f in "$_dir"/progress-*.md; do
        [ -s "$f" ] || continue
        case "$(basename "$f")" in
          *"$display"*) found="$f" ;;
        esac
      done
    done
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
  fi

  return 1
}

# derive_display_name [cwd] [project_dir] [fallback]
# Returns BATON_DISPLAY_NAME if set; otherwise the caller-supplied fallback.
# The cwd and project_dir args are accepted for backwards-compat but are no longer used.
# OSS callers should pass the workstream id as fallback (already unique by construction).
# Users who want dynamic display names set BATON_DISPLAY_NAME in their shell rc.
derive_display_name() {
  local fallback="${3:-}"
  echo "${BATON_DISPLAY_NAME:-$fallback}"
}

# parse_iso8601 <ts> - convert ISO 8601 to epoch seconds with safety semantics.
# Valid → epoch. Missing/malformed/future(>now+86400) → (now - workstream_ttl + 86400),
# i.e., 24h grace before becoming archive-eligible. Logs WARN on any non-valid input.
parse_iso8601() {
  local ts="$1"
  local now epoch
  now=$(date -u +%s)
  local fallback=$((now - $(workstream_ttl_seconds) + 86400))

  if [ -z "$ts" ]; then
    log_event "${CLAUDE_PROJECT_DIR:-$PWD}" workstream-lib parse_iso8601-fallback "reason=empty" 2>/dev/null
    echo "$fallback"
    return 0
  fi

  epoch=$(date -u -d "$ts" +%s 2>/dev/null) || epoch=""
  if [ -z "$epoch" ]; then
    log_event "${CLAUDE_PROJECT_DIR:-$PWD}" workstream-lib parse_iso8601-fallback "reason=malformed" "input=$ts" 2>/dev/null
    echo "$fallback"
    return 0
  fi

  # Future-of-day check: more than 24h ahead of now → treat as malformed.
  if [ "$epoch" -gt $((now + 86400)) ]; then
    log_event "${CLAUDE_PROJECT_DIR:-$PWD}" workstream-lib parse_iso8601-fallback "reason=future" "input=$ts" 2>/dev/null
    echo "$fallback"
    return 0
  fi

  echo "$epoch"
}

# atomic_write <target> - writes stdin to ${target}.tmp.$$ then renames.
# rename(2) is atomic within a filesystem; readers see either the old content
# or the fully-written new content, never partial bytes.
atomic_write() {
  local target="$1"
  local tmp="${target}.tmp.$$"
  if cat > "$tmp"; then
    if mv "$tmp" "$target"; then
      return 0
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# rebind_terminal <tracking_dir> <ws> - point THIS terminal (term_hash) at <ws>.
# Atomically rewrites terminals/<hash>.json, the v2 source of truth the checkpoint
# WRITE path re-reads each fire. Sole binding-writer outside session-start; shared
# by tools/resume.sh and project-detect.sh so the two can never diverge.
rebind_terminal() {
  local tracking="$1" ws="$2"
  local th ts now
  th=$(term_hash)
  ts=$(term_hash_source)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$tracking/terminals"
  jq -n --arg tid "$ts" --arg ws "$ws" --arg now "$now" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$now}' \
    | atomic_write "$tracking/terminals/${th}.json"
}

# workstream_in_use <tracking_dir> <ws_id> - exit 0 if any *fresh* terminals/<hash>.json
# references this workstream id. "Fresh" = its own updated_at is within
# workstream_ttl_seconds. Used by cron Block 4 to skip pruning live workstreams.
workstream_in_use() {
  local tracking="$1" ws="$2"
  local now; now=$(date -u +%s)
  local ttl; ttl=$(workstream_ttl_seconds)
  local cutoff=$((now - ttl))
  local f
  for f in "$tracking/terminals"/*.json; do
    [ -f "$f" ] || continue
    local t_ws t_ts t_epoch
    t_ws=$(jq -r '.workstream // empty' "$f" 2>/dev/null)
    [ "$t_ws" = "$ws" ] || continue
    t_ts=$(jq -r '.updated_at // empty' "$f" 2>/dev/null)
    t_epoch=$(parse_iso8601 "$t_ts")
    if [ "$t_epoch" -ge "$cutoff" ]; then
      return 0
    fi
  done
  return 1
}

# archive_workstream <tracking_dir> <archive_base> <ws_file>
# Holds flock on workstreams/<ws>.json.lock across the move (consistent with
# checkpoint-write-trigger.sh:108-127). Collision-safe: if dest exists, .1 .2 ...
archive_workstream() {
  local tracking="$1" archive="$2" ws_file="$3"
  local ym; ym=$(date +%Y-%m)
  local dest_dir="$archive/checkpoint-state/$ym/workstreams"
  local base; base=$(basename "$ws_file")
  mkdir -p "$dest_dir"

  exec 8>"${ws_file}.lock"
  flock 8 || { exec 8>&-; return 1; }

  local dest="$dest_dir/$base" n=0
  while [ -e "$dest" ]; do
    n=$((n+1))
    dest="$dest_dir/${base}.${n}"
  done
  mv "$ws_file" "$dest"
  local rc=$?

  flock -u 8
  exec 8>&-
  return $rc
}

# archive_session_tracking <tracking_dir> <archive_base> <tracking_file>
# No flock (per-session tracking files are single-writer at SessionStart).
# Collision-safe: same suffix scheme as archive_workstream.
archive_session_tracking() {
  local tracking="$1" archive="$2" tf="$3"
  local ym; ym=$(date +%Y-%m)
  local dest_dir="$archive/checkpoint-state/$ym/sessions-tracking"
  local base; base=$(basename "$tf")
  mkdir -p "$dest_dir"

  local dest="$dest_dir/$base" n=0
  while [ -e "$dest" ]; do
    n=$((n+1))
    dest="$dest_dir/${base}.${n}"
  done
  mv "$tf" "$dest"
}
