#!/bin/bash
# Periodic cleanup - runs every 48h via cron.
# Handles artifacts NOT tied to a specific session:
# - /tmp stragglers from crashed sessions (24h)
# - Progress archive rotation to cold storage (BATON_PROGRESS_COLD_DAYS, default 7d)
# - Stale workstream records (BATON_WORKSTREAM_TTL_DAYS, default 30d)
# - Stale per-session tracking files (BATON_TRACKING_TTL_DAYS, default 7d)
# - Orphaned terminal-state files (72h safety net)
#
# No set -e: cron job must be resilient - each stage runs independently.

PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
BATON_CRON_LOG="${BATON_CRON_LOG:-/tmp/claude-cleanup-cron.log}"
log() { echo "[$(date -Iseconds)] $1" >> "$BATON_CRON_LOG"; }

# Opt-in: --if-due makes this safe to fire blindly every session. Gates on the
# .cron-last-run marker age and self-throttles via a non-blocking sweep lock.
IF_DUE=0
for arg in "$@"; do
  [ "$arg" = "--if-due" ] && IF_DUE=1
done

# Prefer BATON_PROJECT_DIR. Fall back to OLORIN_PROJECT_DIR with deprecation warning.
if [ -n "${OLORIN_PROJECT_DIR:-}" ] && [ -z "${BATON_PROJECT_DIR:-}" ]; then
  log "WARN: OLORIN_PROJECT_DIR is deprecated; set BATON_PROJECT_DIR instead"
  BATON_PROJECT_DIR="$OLORIN_PROJECT_DIR"
fi
PROJECT_DIR="${BATON_PROJECT_DIR:-$PWD}"

# Safety guard: PROJECT_DIR=$HOME with no env var → likely misconfiguration.
if [ "$PROJECT_DIR" = "$HOME" ] && [ -z "${BATON_PROJECT_DIR:-}" ] && [ -z "${OLORIN_PROJECT_DIR:-}" ]; then
  log "WARN: PROJECT_DIR resolved to \$HOME with no env override - aborting"
  exit 0
fi

# Prefer BATON_ARCHIVE_DIR. Fall back to OLORIN_ARCHIVE_DIR with deprecation warning.
if [ -n "${OLORIN_ARCHIVE_DIR:-}" ] && [ -z "${BATON_ARCHIVE_DIR:-}" ]; then
  log "WARN: OLORIN_ARCHIVE_DIR is deprecated; set BATON_ARCHIVE_DIR instead"
  BATON_ARCHIVE_DIR="$OLORIN_ARCHIVE_DIR"
fi

YEAR_MONTH=$(date +%Y-%m)
log "=== Cleanup run ==="

# Source the shared lib for archive helpers + parse_iso8601 + workstream_in_use.
# Resolve relative to THIS script (a same-repo dependency), NOT PROJECT_DIR: the
# code dir and the data dir (PROJECT_DIR) diverge under by-reference installs,
# where PROJECT_DIR holds session data but no copy of the lib. Mandatory - a
# missing lib must abort loudly, never silently run every block with undefined
# functions (which writes a stray .cron-last-run to filesystem root).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOKS_LIB="$REPO_DIR/.claude/hooks/lib/workstream-lib.sh"
if [ ! -f "$HOOKS_LIB" ]; then
  log "FATAL: workstream-lib.sh not found at $HOOKS_LIB - aborting cleanup"
  exit 1
fi
source "$HOOKS_LIB"

TRACKING="$(checkpoint_dir "$PROJECT_DIR")"
ARCHIVE_BASE="$(archive_dir)"

# --if-due self-throttle: hold a non-blocking lock for the whole run and gate on
# the .cron-last-run marker age. Reuses $TRACKING for BOTH the lock and the
# marker so the gate (reader) matches Block 6 (writer). fd 9 stays open until
# the script exits - never wrap the sweep in a subshell, which would drop it.
if [ "$IF_DUE" = "1" ]; then
  mkdir -p "$TRACKING"
  if ! exec 9>"$TRACKING/.sweep.lock"; then
    log "sweep: cannot open lock at $TRACKING/.sweep.lock, skip"
    exit 0
  fi
  flock -n 9 || { log "sweep: in progress, skip"; exit 0; }
  SWEEP_INTERVAL_HOURS=$(sweep_interval_hours)
  if [ -f "$TRACKING/.cron-last-run" ] && \
     [ -n "$(find "$TRACKING" -maxdepth 1 -name .cron-last-run -mmin -"$((SWEEP_INTERVAL_HOURS*60))" 2>/dev/null)" ]; then
    log "sweep: not due (interval=${SWEEP_INTERVAL_HOURS}h)"
    exit 0
  fi
fi

# === Block 1: /tmp sweep ===
# Patterns are single-session keys safe to delete after BATON_TMP_TTL_HOURS
# (default 24h). Live sessions refresh their own keys on each turn, so an entry
# older than the safety window is necessarily orphaned by a crashed/killed
# session. tmp_ttl_minutes() comes from workstream-lib.sh (E1-T1).
SWEEP_PATTERNS=(
  'claude-context-triggered-*'
  'claude-context-pct-*'
  'baton-warned-*'
  'baton-nag-*'
  'baton-health-*'
  'baton-done-*'
  'baton-relaunch-*'
  'baton-pending-*'
  'baton-archive-*'
  'baton-manual-*'
  'baton-consent-*'
  'baton-unlock-*'
  'baton-snooze-*'
  'claude-subagent-checkpoint-*'
  'claude-session-tracking-*'
  'claude-parent-sid-*'
  'claude-tab-title-*'
)
TMP_TTL_MIN=$(tmp_ttl_minutes)
CLEANED=0
for pat in "${SWEEP_PATTERNS[@]}"; do
  N=$(find /tmp -maxdepth 1 -name "$pat" -mmin +"$TMP_TTL_MIN" -delete -print 2>/dev/null | wc -l)
  CLEANED=$((CLEANED + N))
done
# Active-subagent marker dirs (drain gate). Directories, so rm -rf, not -delete.
DIRN=0
while IFS= read -r -d '' d; do
  rm -rf "$d" 2>/dev/null && DIRN=$((DIRN+1))
done < <(find /tmp -maxdepth 1 -type d -name 'baton-subagents-active-*' -mmin +"$TMP_TTL_MIN" -print0 2>/dev/null)
CLEANED=$((CLEANED + DIRN))
log "Block 1: cleaned $CLEANED stale /tmp files (TTL=${TMP_TTL_MIN}m)"

# === Block 2: archive per-session tracking files ===
# BATON_TRACKING_TTL_DAYS (default 7d). Uses file mtime - these are
# single-write at SessionStart, so mtime is the correct signal.
TRACK_TTL_MIN=$(( $(tracking_ttl_seconds) / 60 ))
TRACK_ARCHIVED=0
while IFS= read -r -d '' tf; do
  archive_session_tracking "$TRACKING" "$ARCHIVE_BASE" "$tf" && TRACK_ARCHIVED=$((TRACK_ARCHIVED+1))
done < <(find "$TRACKING" -maxdepth 1 -name "*.json" -mmin +$TRACK_TTL_MIN -print0 2>/dev/null)
log "Block 2: archived $TRACK_ARCHIVED per-session tracking files"

# === Block 3: delete stale terminal records (identity layer carve-out per CC4) ===
# Identity records regenerate on next SessionStart from term_hash(); deleting is safe.
# 72h fixed (not env-driven) - identity layer cleanup is not user-facing.
PRUNED=$(find "$TRACKING/terminals" \
  -maxdepth 1 -name "*.json" -mmin +4320 -delete -print 2>/dev/null | wc -l || echo 0)
PRUNED_LOCKS=$(find "$TRACKING" \
  -name "*.lock" -mmin +4320 -delete -print 2>/dev/null | wc -l || echo 0)
log "Block 3: pruned $PRUNED terminal files, $PRUNED_LOCKS locks"

# === Block 4: archive stale workstream records ===
# BATON_WORKSTREAM_TTL_DAYS (default 30d). Reads JSON updated_at via
# parse_iso8601 (NOT file mtime - see CC4). Skips workstreams referenced by
# any fresh terminal (workstream_in_use). Order: AFTER Block 3 so dead
# terminal pointers don't pin live workstreams.
WS_TTL=$(workstream_ttl_seconds)
NOW=$(date -u +%s)
WS_CUTOFF=$((NOW - WS_TTL))
WS_ARCHIVED=0
WS_SKIPPED_INUSE=0
for w in "$TRACKING/workstreams"/*.json; do
  [ -f "$w" ] || continue
  WS_ID=$(jq -r '.workstream // empty' "$w" 2>/dev/null)
  [ -z "$WS_ID" ] && continue

  if workstream_in_use "$TRACKING" "$WS_ID"; then
    WS_SKIPPED_INUSE=$((WS_SKIPPED_INUSE+1))
    continue
  fi

  WS_TS=$(jq -r '.updated_at // empty' "$w" 2>/dev/null)
  WS_EPOCH=$(parse_iso8601 "$WS_TS")
  if [ "$WS_EPOCH" -lt "$WS_CUTOFF" ]; then
    archive_workstream "$TRACKING" "$ARCHIVE_BASE" "$w" \
      && WS_ARCHIVED=$((WS_ARCHIVED+1))
  fi
done
log "Block 4: archived $WS_ARCHIVED stale workstreams, skipped $WS_SKIPPED_INUSE in-use"

# === Block 5: two-tier progress archive ===
# Recent tier: $ARCHIVE_BASE/progress/<YYYY-MM>/  - written by checkpoint-write-trigger.sh.
# Cold tier:   $ARCHIVE_BASE/progress-cold/<YYYY-MM>/ - a plain move, no compression, so
# both tiers stay readable by the same tools with no decompression step anywhere.
# The source partition directory is preserved, so no date arithmetic decides the
# destination.
#
# Age comes from the write timestamp embedded in the basename, NEVER from mtime:
# the archival move into the recent tier rewrites mtime, so an mtime-based sweep
# would measure time-since-archival and never fire on a file that was archived
# once and left alone. A basename with no parseable trailing timestamp is left in
# place and counted, not guessed at.
progress_write_epoch() {
  local base="${1##*/}"
  base="${base%.md}"
  if [[ "$base" =~ -([0-9]{8})-([0-9]{6})(-[0-9]+)?$ ]]; then
    local d="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}"
    date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null
    return $?
  fi
  return 1
}

# The window and its non-integer clamp both come from progress_cold_days() in
# workstream-lib.sh, which this script already sources. _cfg::get can hand back a
# non-integer - a hand-edited config.json, a typo'd env var - and this script has no
# `set -e`, so the arithmetic below would not abort on one; it would silently compute
# a garbage cutoff. A local copy of the clamp here would put the rule in two places,
# and the dashboard's [TTLs] row reads the same accessor, which is what keeps a shown
# value from disagreeing with the gate (lib/config.sh:6-10).
if ! command -v progress_cold_days >/dev/null 2>&1; then
  log "FATAL: progress_cold_days is not defined in workstream-lib.sh - skipping Block 5"
else
PROG_COLD_DAYS=$(progress_cold_days)
PROG_CUTOFF=$(( $(date +%s) - PROG_COLD_DAYS * 86400 ))
COLD_MOVED=0
COLD_SKIPPED=0
# A failed move is counted and named, never swallowed: an unwritable or full cold
# tier would otherwise log byte-identically to an idle sweep while the recent tier
# grows unboundedly. The count is APPENDED to the summary line - the cron log is
# grepped on its existing prefix, so the leading text must not be restructured.
COLD_FAILED=0
for pf in "$ARCHIVE_BASE/progress"/*/*.md; do
  [ -f "$pf" ] || continue
  PF_EPOCH=$(progress_write_epoch "$pf") || { COLD_SKIPPED=$((COLD_SKIPPED+1)); continue; }
  [ -n "$PF_EPOCH" ] || { COLD_SKIPPED=$((COLD_SKIPPED+1)); continue; }
  [ "$PF_EPOCH" -lt "$PROG_CUTOFF" ] || continue
  PF_PART=$(basename "$(dirname "$pf")")
  mkdir -p "$ARCHIVE_BASE/progress-cold/$PF_PART"
  if mv "$pf" "$ARCHIVE_BASE/progress-cold/$PF_PART/" 2>/dev/null; then
    COLD_MOVED=$((COLD_MOVED+1))
  else
    COLD_FAILED=$((COLD_FAILED+1))
    log "WARN: cold-tier move failed for $pf"
  fi
done
log "Block 5: moved $COLD_MOVED progress files to cold storage (older than ${PROG_COLD_DAYS}d), skipped $COLD_SKIPPED with no embedded write timestamp, $COLD_FAILED failed"
fi

# === Block 6: writer for cron-not-running probe (E5a reads .cron-last-run) ===
CD=$(checkpoint_dir "$PROJECT_DIR")
mkdir -p "$CD"
touch "$CD/.cron-last-run"
log "Block 6: refreshed $CD/.cron-last-run"

# === Block 7: truncate debug log if > 100KB ===
DEBUG_LOG="/tmp/claude-ws-debug.log"
if [ -f "$DEBUG_LOG" ]; then
  SIZE=$(stat -c %s "$DEBUG_LOG" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt "${_BATON_DEBUG_LOG_MAX_BYTES:-102400}" ]; then
    tail -50 "$DEBUG_LOG" > "${DEBUG_LOG}.tmp" && mv "${DEBUG_LOG}.tmp" "$DEBUG_LOG"
  fi
  log "Block 7: debug log: ${SIZE} bytes"
fi

log "=== Done ==="
