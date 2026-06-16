#!/bin/bash
# Tests for tools/restore-workstream.sh - archive → restore round-trip.
set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
RESTORE="$PROJECT_ROOT/tools/restore-workstream.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); echo "  PASS  $name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"; fi
}

mkproj() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking/workstreams" \
           "$d/docs/sessions/.tracking/terminals" \
           "$d/.claude/hooks/lib"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$d/.claude/hooks/lib/workstream-lib.sh"
  echo "$d"
}

run_restore_basic() {
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  local archive="$proj/archive-base"
  local ym; ym=$(date +%Y-%m)
  mkdir -p "$archive/checkpoint-state/$ym/workstreams" "$archive/progress/$ym"

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local prog="$archive/progress/$ym/progress-ws-restore-20260101.md"
  echo "# restored progress" > "$prog"

  jq -n --arg ws "ws-restore" --arg ts "$now" --arg p "$prog" \
    '{workstream:$ws, display_name:"r", progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$archive/checkpoint-state/$ym/workstreams/ws-restore.json"

  # E5a-T4: restore now threads checkpoint_dir; pin BATON_DIR to the
  # legacy tracking path so assertions on $tracking/workstreams stay valid.
  BATON_DIR="$tracking" OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$RESTORE" ws-restore

  assert "restore-ws-record-back" '[ -f "$tracking/workstreams/ws-restore.json" ]'
  assert "restore-ws-record-readable" 'jq -e . "$tracking/workstreams/ws-restore.json" >/dev/null'
  rm -rf "$proj"
}

run_restore_progress_too() {
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  local archive="$proj/archive-base"
  local ym; ym=$(date +%Y-%m)
  mkdir -p "$archive/checkpoint-state/$ym/workstreams" "$archive/progress/$ym"
  mkdir -p "$proj/docs/sessions"

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local prog_archive="$archive/progress/$ym/progress-ws-restoreP-20260101.md"
  echo "# restored prog" > "$prog_archive"
  local prog_target="$proj/docs/sessions/progress-ws-restoreP-20260101.md"

  jq -n --arg ws "ws-restoreP" --arg ts "$now" --arg p "$prog_target" \
    '{workstream:$ws, display_name:"r", progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$archive/checkpoint-state/$ym/workstreams/ws-restoreP.json"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$RESTORE" ws-restoreP

  assert "restore-progress-back" '[ -f "$prog_target" ]'
  rm -rf "$proj"
}

run_restore_idempotent() {
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  local archive="$proj/archive-base"
  local ym; ym=$(date +%Y-%m)
  mkdir -p "$archive/checkpoint-state/$ym/workstreams"

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "ws-idem" --arg ts "$now" \
    '{workstream:$ws, display_name:"i", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$archive/checkpoint-state/$ym/workstreams/ws-idem.json"

  BATON_DIR="$tracking" OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" bash "$RESTORE" ws-idem
  BATON_DIR="$tracking" OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" bash "$RESTORE" ws-idem
  local rc=$?

  assert "restore-idempotent-rc-zero" '[ "$rc" = "0" ]'
  assert "restore-idempotent-record-present" '[ -f "$tracking/workstreams/ws-idem.json" ]'
  rm -rf "$proj"
}

run_restore_missing_input() {
  local proj; proj=$(mkproj)
  local archive="$proj/archive-base"
  mkdir -p "$archive/checkpoint-state"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" bash "$RESTORE" ws-not-here
  local rc=$?

  assert "restore-missing-rc-nonzero" '[ "$rc" != "0" ]'
  rm -rf "$proj"
}

run_archive_restore_roundtrip() {
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  mkdir -p "$tracking/terminals" "$proj/docs/sessions" "$proj/docs/archive"
  local archive="$proj/archive-base"

  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  local prog="$proj/docs/sessions/progress-ws-rt-20260101.md"
  echo "# rt" > "$prog"
  jq -n --arg ws "ws-rt" --arg ts "$stale" --arg p "$prog" \
    '{workstream:$ws, display_name:"rt", progress_file:$p, phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-rt.json"

  # Cron archives the record. Block 5 only rotates from docs/archive/, so we
  # manually stage the progress in archive/progress/$ym/ to simulate prior rotation.
  # BATON_DIR pins the new-default tracking dir back to the legacy path so
  # cron looks where the test planted ws-rt.json ($proj/.baton is the default).
  BATON_DIR="$tracking" OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  local ym; ym=$(date +%Y-%m)
  assert "rt-archived" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-rt.json" ]'

  mkdir -p "$archive/progress/$ym"
  cp "$prog" "$archive/progress/$ym/$(basename "$prog")"
  rm -f "$prog"

  # Restore. Pin BATON_DIR to the legacy tracking path (E5a-T4 threading).
  BATON_DIR="$tracking" OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$RESTORE" ws-rt

  assert "rt-record-restored" '[ -f "$tracking/workstreams/ws-rt.json" ]'
  assert "rt-progress-restored" '[ -f "$prog" ]'

  rm -rf "$proj"
}

run_restore_honors_checkpoint_dir() {
  local proj; proj=$(mktemp -d)
  local custom="$proj/custom-checkpoint-root"
  mkdir -p "$custom/workstreams" "$proj/.claude/hooks/lib"
  ln -sf "$(cd "$(dirname "$0")/.." && pwd)/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive; archive=$(mktemp -d)
  mkdir -p "$archive/checkpoint-state/2026-05/workstreams"
  jq -n --arg pd "$proj" \
    '{workstream:"thread-ws", display_name:"T", project_dir:$pd, updated_at:"2026-05-09T00:00:00Z", phase:"impl"}' \
    > "$archive/checkpoint-state/2026-05/workstreams/thread-ws.json"
  BATON_PROJECT_DIR="$proj" BATON_DIR="$custom" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$(cd "$(dirname "$0")/../../.." && pwd)/tools/restore-workstream.sh" thread-ws >/dev/null 2>&1
  local rc=$?
  assert "THREAD-CHECKPOINT-DIR: restore exits 0" "[ $rc -eq 0 ]"
  rm -rf "$proj" "$archive"
}

run_restore_basic
run_restore_progress_too
run_restore_idempotent
run_restore_missing_input
run_archive_restore_roundtrip
run_restore_honors_checkpoint_dir

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
