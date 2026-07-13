#!/bin/bash
# tools/doctor.sh - baton health probe (E7-T6 foundation).
#
# Checks:
#   1. Resolves $BATON_EVENT_LOG (default: $XDG_STATE_HOME/baton/hook-events.jsonl
#      or ~/.local/state/baton/hook-events.jsonl).
#   2. FS-type warning for nfs/nfs4/cifs/smbfs (flock can be unreliable).
#   3. Log-file mode check: expected 0600.
#   4. Parent-dir existence + mode reporting.
#
# Exit: 0 if all green, 1 if any warning fired. Always prints a summary line.
# No network. Read-only.
set -u

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"   # CC6

WARNED=0

: "${_DOCTOR_ANOMALY_LOOKBACK_SECONDS:=86400}"   # 24h cache-anomaly look-back
: "${_PRICING_STALE_DAYS:=90}"   # warn when PRICING_VERIFIED_DATE older than N days

# Default log location.
default_event_log() {
  local base="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
  echo "$base/hook-events.jsonl"
}

# FS-type detection helper. Exported semantics: prints the fs type for $1.
# Linux: `stat -f -c %T <dir>` (covered by GNU coreutils + busybox-ish stat).
# macOS fallback: `df -T` or mount parsing - not exercised here but stubbed.
# Shared with T7 (lock-path probe); keep this helper minimal.
checkpoint_fs_type() {
  local path="$1"
  if stat -f -c %T "$path" >/dev/null 2>&1; then
    stat -f -c %T "$path" 2>/dev/null
    return 0
  fi
  # macOS path (BSD stat lacks -f -c). Best-effort via df.
  if command -v df >/dev/null 2>&1; then
    df -T "$path" 2>/dev/null | tail -n +2 | awk '{print $2; exit}'
    return 0
  fi
  echo "unknown"
}

is_network_fs() {
  case "$1" in
    nfs|nfs4|cifs|smbfs) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve log path.
LOG="$(_cfg::get BATON_EVENT_LOG "$(default_event_log)")"
PARENT="$(dirname "$LOG")"

echo "doctor: event log path: $LOG"

# Parent dir reporting + FS-type detection.
PROBE_PATH="$PARENT"
if [ ! -d "$PROBE_PATH" ]; then
  echo "doctor: parent dir does not exist: $PARENT"
  # Walk up to nearest existing ancestor for FS detection.
  PROBE_PATH="$PARENT"
  while [ -n "$PROBE_PATH" ] && [ ! -d "$PROBE_PATH" ]; do
    PROBE_PATH="$(dirname "$PROBE_PATH")"
    [ "$PROBE_PATH" = "/" ] && break
  done
else
  PARENT_MODE="$(stat -c %a "$PARENT" 2>/dev/null || echo '?')"
  echo "doctor: parent dir mode: $PARENT_MODE"
fi

FSTYPE="$(checkpoint_fs_type "$PROBE_PATH")"
echo "doctor: fs type: ${FSTYPE:-unknown}"

if is_network_fs "$FSTYPE"; then
  echo "WARN: $LOG is on $FSTYPE; flock semantics may be unreliable; see docs/telemetry.md §NFS" >&2
  WARNED=1
fi

# Log-file checks.
if [ -e "$LOG" ]; then
  MODE="$(stat -c %a "$LOG" 2>/dev/null || echo '?')"
  echo "doctor: log mode: $MODE"
  if [ "$MODE" != "600" ]; then
    echo "WARN: log mode is $MODE, expected 600" >&2
    WARNED=1
  fi
else
  echo "doctor: no log yet at $LOG"
fi

# E8-T6: Cache anomalies (last 24h)
if [ -f "$LOG" ]; then
  now_epoch=$(date -u +%s)
  cutoff=$((now_epoch - _DOCTOR_ANOMALY_LOOKBACK_SECONDS))
  anomaly_count=0
  while IFS= read -r entry; do
    ts_str=$(printf '%s' "$entry" | jq -r '.ts // ""' 2>/dev/null)
    [ -z "$ts_str" ] && continue
    entry_epoch=$(date -u -d "$ts_str" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_str" +%s 2>/dev/null || echo 0)
    [ "$entry_epoch" -ge "$cutoff" ] && anomaly_count=$((anomaly_count + 1))
  done < <(grep '"event":"cache_anomaly"' "$LOG" 2>/dev/null || true)
  if [ "$anomaly_count" -gt 0 ]; then
    echo "WARNING: $anomaly_count cache anomaly events in last 24h - see hook-events.jsonl" >&2
    WARNED=1
  else
    echo "OK: no cache anomalies in last 24h"
  fi
else
  echo "OK: no cache anomalies in last 24h"
fi

# E19 T8a: crontab cleanup-cron-wrapper line check.
if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -q cleanup-cron-wrapper; then
    echo 'OK: crontab cleanup-cron-wrapper line present'
  else
    echo 'WARN: crontab cleanup-cron-wrapper line missing (cron sweep not active; manual install may have skipped this step)' >&2
    WARNED=1
  fi
else
  echo 'doctor: crontab not available; skipping cron-line check'
fi

# E19 T8b: statusline shim presence in ~/.claude/settings.json.
SETTINGS_FILE="${BATON_DOCTOR_SETTINGS:-$HOME/.claude/settings.json}"
if [ -f "$SETTINGS_FILE" ] && ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
  printf 'WARN: %s is not valid JSON (parse error); skipping statusLine shape check\n' "$SETTINGS_FILE" >&2
  WARNED=1
else
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "doctor: $SETTINGS_FILE not found; skipping statusline check"
  elif jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null | grep -q baton-pct.sh; then
    echo 'OK: statusLine.command includes baton-pct.sh'
  else
    printf 'WARN: statusLine.command in %s does not reference baton-pct.sh (manual install may have skipped statusline wiring)\n' "$SETTINGS_FILE" >&2
    WARNED=1
  fi
fi

# E8-T6: Pricing freshness
_cost_models_path="${BATON_COST_MODELS_PATH:-$(dirname "$0")/../lib/cost-models.sh}"
if [ -f "$_cost_models_path" ]; then
  # shellcheck source=../lib/cost-models.sh
  source "$_cost_models_path"
  if [ -z "${PRICING_VERIFIED_DATE:-}" ]; then
    echo "doctor: cost-models.sh did not define PRICING_VERIFIED_DATE, skipping freshness check"
  else
    now_epoch=$(date -u +%s)
    verified_epoch=$(date -u -d "$PRICING_VERIFIED_DATE" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%d" "$PRICING_VERIFIED_DATE" +%s 2>/dev/null \
      || echo 0)
    age_days=$(( (now_epoch - verified_epoch) / 86400 ))
    if [ "$age_days" -gt "$_PRICING_STALE_DAYS" ]; then
      echo "WARNING: PRICING_VERIFIED_DATE=$PRICING_VERIFIED_DATE, age=$age_days days - re-verify against https://platform.claude.com/docs/en/about-claude/pricing" >&2
      WARNED=1
    else
      echo "OK: PRICING_VERIFIED_DATE=$PRICING_VERIFIED_DATE, age=$age_days days"
    fi
  fi
else
  echo "doctor: cost-models.sh not found at $_cost_models_path, skipping freshness check"
fi

if [ "$WARNED" -eq 0 ]; then
  echo "summary: ok"
  exit 0
else
  echo "summary: warnings present (exit 1)"
  exit 1
fi
