#!/usr/bin/env bash
# drain-gate.sh - "is it safe to write the checkpoint?" primitive.
# Active-subagent markers are one file per agent_id under a per-parent dir; the
# count is a directory listing (no shared-integer read-modify-write race).
# Sourced by subagent-track-start.sh (writer), post-subagent-cost.sh (writer)
# and context-checkpoint.sh (reader). No side effects at source time.
#
# HARD-DEPENDENCY / fail-loud contract: this lib is the correctness core of the
# checkpoint gate. Consumers MUST treat a failed `source` or a missing
# drain::is_clear as FATAL (log a trace + HOLD the write), never as "drain
# clear" - degrading silently reopens the dropped-work bug the gate exists to
# close. Enforcement lives in context-checkpoint.sh's owed-checkpoint block
# (the drain-gate-unavailable trace), scoped to genuine source failure only.

# Seconds after which an unfinished subagent is treated as hung and the drain
# offers a force-past escape. Measured from SubagentStart, so this is TOTAL
# elapsed runtime, not time-since-progress - set it above a realistic ceiling
# for your longest subagent or healthy work gets offered up for discard.
# Env-overridable.
: "${BATON_DRAIN_TIMEOUT_SECS:=360}"

drain::marker_dir() {  # <parent_sid> -> prints dir path, rc1 on bad id
  local psid="$1"
  case "$psid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '/tmp/baton-subagents-active-%s' "$psid"
}

drain::mark_start() {  # <parent_sid> <agent_id>
  local dir aid="$2"
  case "$aid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  dir="$(drain::marker_dir "$1")" || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  : > "$dir/$aid" 2>/dev/null && return 0
  # A concurrent mark_stop can rmdir the tidy-up window between the mkdir above
  # and this create. Losing that race must not silently drop a live subagent
  # from the count, so recreate and retry exactly once.
  mkdir -p "$dir" 2>/dev/null || return 1
  : > "$dir/$aid" 2>/dev/null || return 1
}

drain::mark_stop() {  # <parent_sid> <agent_id>
  local dir aid="$2"
  case "$aid" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  dir="$(drain::marker_dir "$1")" || return 0
  rm -f "$dir/$aid" 2>/dev/null || true
  rmdir "$dir" 2>/dev/null || true  # tidy when the last subagent leaves
}

drain::count() {  # <parent_sid> -> prints integer
  local dir n
  dir="$(drain::marker_dir "$1")" || { printf '0'; return 0; }
  [ -d "$dir" ] || { printf '0'; return 0; }
  n=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
  printf '%s' "${n:-0}"
}

drain::is_clear() {  # <parent_sid> -> rc0 when no active subagents
  [ "$(drain::count "$1")" -eq 0 ]
}

# Oldest active marker age in seconds (0 when clear). mtime == SubagentStart time
# (markers are written once). GNU find -printf; guarded so a miss yields 0.
drain::oldest_age() {  # <parent_sid> -> prints integer seconds
  local dir oldest now
  dir="$(drain::marker_dir "$1")" || { printf '0'; return 0; }
  [ -d "$dir" ] || { printf '0'; return 0; }
  oldest=$(find "$dir" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | head -1)
  [ -z "$oldest" ] && { printf '0'; return 0; }
  now=$(date +%s)
  printf '%s' "$(( now - ${oldest%.*} ))"
}

drain::hung() {  # <parent_sid> -> rc0 when oldest active subagent exceeds timeout
  local age; age=$(drain::oldest_age "$1")
  [ "$age" -ge "${BATON_DRAIN_TIMEOUT_SECS:-360}" ]
}
