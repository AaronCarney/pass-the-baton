#!/usr/bin/env bash
# tools/repair-event-log.sh - backup-first repair of the hook-events.jsonl stream (CC20).
#
# The event log is a BEST-EFFORT append stream; crash / VM-pause zero-fill can leave
# NUL runs or blank lines (see lib/eventlog.sh). Readers tolerate this on the READ side,
# but a one-time compaction keeps the live file clean. This tool reuses eventlog::stream
# to rewrite the log to ONLY valid JSON records - backup-first, never truncating before a
# verified backup exists.
#
# Usage:
#   tools/repair-event-log.sh [--dry-run] [PATH]
#   tools/repair-event-log.sh --help
#
# PATH defaults to the same resolver the readers use:
#   $BATON_EVENT_LOG (default $XDG_STATE_HOME/baton/hook-events.jsonl).
#
# Exit codes: 0 ok; non-zero on resolve failure, missing log, or backup failure.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck disable=SC1090
source "$REPO_ROOT/lib/eventlog.sh"

die(){ echo "repair-event-log: $1" >&2; exit 1; }

DRY_RUN=0
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --) shift; [ $# -gt 0 ] && LOG="$1"; break ;;
    -*) die "unknown option: $1" ;;
    *) LOG="$1"; shift ;;
  esac
done

if [ -z "$LOG" ]; then
  LOG="${BATON_EVENT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl}"
fi

[ -e "$LOG" ] || die "log not found: $LOG"
[ -f "$LOG" ] || die "not a regular file: $LOG"
[ -r "$LOG" ] || die "log not readable: $LOG"

# awk NR counts an unterminated final line (matching jq -cR line semantics);
# wc -l would miss it and under-report total, masking a real drop.
total="$(awk 'END{print NR}' "$LOG")"
kept="$(eventlog::stream "$LOG" | wc -l | tr -d ' ')"
dropped=$(( total - kept ))
[ "$dropped" -lt 0 ] && dropped=0

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: $LOG"
  echo "  total lines: $total"
  echo "  kept records: $kept"
  echo "  dropped: $dropped"
  exit 0
fi

# Backup-first: copy preserving mode/timestamps, verify it exists and size matches.
bak="$LOG.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$LOG" "$bak" 2>/dev/null || die "backup failed (could not write $bak)"
[ -f "$bak" ] || die "backup missing after copy: $bak"
src_sz="$(wc -c < "$LOG" | tr -d ' ')"
bak_sz="$(wc -c < "$bak" | tr -d ' ')"
[ "$src_sz" = "$bak_sz" ] || die "backup size mismatch ($src_sz != $bak_sz)"

# Rewrite via a temp file in the same dir, chmod 0600, atomic mv.
tmp="$(mktemp "$LOG.repair.XXXXXX")" || die "could not create temp file"
trap 'rm -f "$tmp"' EXIT
eventlog::stream "$LOG" > "$tmp" || die "stream failed; original untouched (backup: $bak)"
chmod 0600 "$tmp"
mv "$tmp" "$LOG" || die "could not replace log; original untouched (backup: $bak)"
trap - EXIT

echo "repaired: $LOG"
echo "  total lines: $total"
echo "  kept records: $kept"
echo "  dropped: $dropped"
echo "  backup: $bak"
