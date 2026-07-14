#!/bin/bash
# Shared workstream functions for checkpoint hooks.

# CC6: source the shared _cfg::get resolver (env > config.json > default).
# Self-contained: guard-source lib/config.sh; if unreachable, define a
# FAITHFUL inline fallback so a dashboard config.json write is still honored
# under plugin distribution. Precedent: .claude/hooks/lib/envelope.sh:26-48.
# Guard on _cfg::path (a non-exported helper config.sh's _cfg::get depends on):
# config.sh exports only _cfg::get, so a child process can inherit _cfg::get
# WITHOUT _cfg::path. Re-sourcing when _cfg::path is absent restores the full
# helper set; gating on _cfg::get alone would leave _cfg::get calling a missing
# _cfg::path in subshells (cron sweep regression).
if ! declare -F _cfg::path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/config.sh" 2>/dev/null || true
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

# E5 single-source constants (idempotent :=, re-source-safe).
: "${_WS_CLOCK_GRACE_SECONDS:=86400}"   # 24h clock-skew grace for ISO8601 parse windows
: "${_BATON_DEBUG_LOG_MAX_BYTES:=102400}"  # 100KB debug-log truncation cap (shared by cleanup paths)

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
  # Single source of truth for the checkpoint trigger threshold (a context-fill
  # percentage). env > config.json > default via _cfg::get, then bounds-clamped:
  # an integer in 1..99 is honored; anything else falls back to the default.
  # Both the gate (context-checkpoint.sh) and the PreToolUse telemetry field read
  # through here, so the trigger and the reported `threshold` are always equal.
  # _def is the compiled default; ${BATON_DEFAULT_PCT_THRESHOLD:-20} is a FAITHFUL
  # fallback (bound to the lib/config.sh constant) for the guard-source-failed case.
  local _def="${BATON_DEFAULT_PCT_THRESHOLD:-20}" _t
  _t="$(_cfg::get BATON_PCT_THRESHOLD "$_def" threshold_pct)"
  if [[ "$_t" =~ ^[0-9]+$ ]] && [ "$_t" -ge 1 ] && [ "$_t" -le 99 ]; then
    printf '%s' "$_t"
  else
    printf '%s' "$_def"
  fi
}

# checkpoint_dir <project_dir> - root for tracking state. Default: $project_dir/.baton (CC1).
# NOTE (CC6): BATON_DIR stays ENV-ONLY by design - it locates the state dir (and thus the
# forensic event log); it is deliberately not read from config.json.
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
  _cfg::get BATON_PROGRESS_DIR "$(checkpoint_dir "$1")/progress"
}

# archive_dir - XDG-aligned archive root, no project arg (archives are user-global).
archive_dir() {
  _cfg::get BATON_ARCHIVE_DIR "$HOME/.local/share/baton"
}

# TTL helpers - return seconds (or minutes for /tmp sweep).
workstream_ttl_seconds() {
  local d; d="$(_cfg::get BATON_WORKSTREAM_TTL_DAYS 30)"
  echo $((d * 86400))
}

tracking_ttl_seconds() {
  local d; d="$(_cfg::get BATON_TRACKING_TTL_DAYS 7)"
  echo $((d * 86400))
}

tmp_ttl_minutes() {
  local h; h="$(_cfg::get BATON_TMP_TTL_HOURS 24)"
  echo $((h * 60))
}

# Sweep self-throttle interval (hours). Single source for the BATON_SWEEP_INTERVAL_HOURS
# default; NOT the OS-cron cadence (that is BATON_CRON_SCHEDULE in tools/lib/cron-schedule.sh).
sweep_interval_hours() { _cfg::get BATON_SWEEP_INTERVAL_HOURS 48; }

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

  # Build list of dirs to search: BATON_PROGRESS_DIR (env > config.json) if set,
  # else $sessions_dir. No symlink-walk. OSS code has no knowledge of projects/.
  local search_dirs=() progress_override
  progress_override="$(_cfg::get BATON_PROGRESS_DIR '')"
  if [ -n "$progress_override" ]; then
    search_dirs=("$progress_override")
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
  _cfg::get BATON_DISPLAY_NAME "$fallback" display_name
}

# parse_iso8601 <ts> - convert ISO 8601 to epoch seconds with safety semantics.
# Valid → epoch. Missing/malformed/future(>now+86400) → (now - workstream_ttl + 86400),
# i.e., 24h grace before becoming archive-eligible. Logs WARN on any non-valid input.
parse_iso8601() {
  local ts="$1"
  local now epoch
  now=$(date -u +%s)
  local fallback=$((now - $(workstream_ttl_seconds) + _WS_CLOCK_GRACE_SECONDS))

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
  if [ "$epoch" -gt $((now + _WS_CLOCK_GRACE_SECONDS)) ]; then
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
# by project-detect.sh so the two can never diverge.
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

# find_workstream_by_session_id <tracking_dir> <session_id> - crash-recovery
# reverse lookup. Echoes the workstream id of the record whose additive
# .session_id equals <session_id>; on multiple matches the most-recently-updated
# (updated_at) wins. Empty session_id or no match -> no output, return 1.
# Records predating the additive session_id field never match (`.session_id //
# empty`). Consulted only on a terminals/<hash>.json miss (session-start routing).
find_workstream_by_session_id() {
  local tracking="$1" sid="$2"
  [ -n "$sid" ] || return 1
  local best="" best_epoch=-1 f
  for f in "$tracking/workstreams"/*.json; do
    [ -f "$f" ] || continue
    local f_sid; f_sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
    [ "$f_sid" = "$sid" ] || continue
    local f_ws; f_ws=$(jq -r '.workstream // empty' "$f" 2>/dev/null)
    [ -n "$f_ws" ] || continue
    local f_epoch; f_epoch=$(parse_iso8601 "$(jq -r '.updated_at // empty' "$f" 2>/dev/null)")
    if [ "$f_epoch" -gt "$best_epoch" ]; then
      best_epoch="$f_epoch"; best="$f_ws"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
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

# workstream_roster <tracking> <ws> [exclude_hash] - print, one per line, the term_hash of
# every FRESH terminal bound to <ws>: updated_at within TTL and no .closed_at. Skips
# exclude_hash (the caller's own hash) when given.
workstream_roster() {
  local tracking="$1" ws="$2" excl="${3:-}"
  local now cutoff ttl f base
  now=$(date -u +%s); ttl=$(workstream_ttl_seconds); cutoff=$((now - ttl))
  for f in "$tracking/terminals"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .json)
    [ -n "$excl" ] && [ "$base" = "$excl" ] && continue
    [ "$(jq -r '.workstream // empty' "$f" 2>/dev/null)" = "$ws" ] || continue
    [ -n "$(jq -r '.closed_at // empty' "$f" 2>/dev/null)" ] && continue
    local e; e=$(parse_iso8601 "$(jq -r '.updated_at // empty' "$f" 2>/dev/null)")
    [ "$e" -ge "$cutoff" ] && printf '%s\n' "$base"
  done
}

# workstream_terminal_count <tracking> <ws> [exclude_hash] - number of fresh co-tenants.
workstream_terminal_count() {
  workstream_roster "$1" "$2" "${3:-}" | grep -c . || true
}

# workstream_is_fresh <ws_file> - exit 0 iff the workstream has never been checkpointed
# (progress_file empty AND phase unknown). Missing/corrupt file -> not fresh (return 1).
workstream_is_fresh() {
  local wf="$1"
  [ -f "$wf" ] || return 1
  local pf ph
  pf=$(jq -r '.progress_file // empty' "$wf" 2>/dev/null) || return 1
  ph=$(jq -r '.phase // empty' "$wf" 2>/dev/null)
  [ -z "$pf" ] && [ "$ph" = "unknown" ]
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
