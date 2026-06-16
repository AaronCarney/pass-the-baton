#!/bin/bash
# Tests for tools/resume.sh canonical workstream-recovery CLI.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
RESUME="$REPO_DIR/tools/resume.sh"
RESTORE="$REPO_DIR/tools/restore-workstream.sh"

PASSED=0
FAILED=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASSED=$((PASSED+1)); echo "  PASS  $name"
  else
    FAILED=$((FAILED+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

mkr() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.baton/workstreams" "$d/.baton/terminals"
  echo "$d"
}

# Stub: link .claude/hooks/lib/workstream-lib.sh from real repo so resume.sh's source resolves.
link_lib() {
  local d="$1"
  mkdir -p "$d/.claude/hooks/lib"
  ln -sf "$REPO_DIR/.claude/hooks/lib/workstream-lib.sh" "$d/.claude/hooks/lib/workstream-lib.sh"
  mkdir -p "$d/tools"
  ln -sf "$RESTORE" "$d/tools/restore-workstream.sh"
}

echo "## resume.sh - list + rebind"

run_lists_archived() {
  local proj; proj=$(mkr); link_lib "$proj"
  local archive; archive=$(mktemp -d)
  mkdir -p "$archive/checkpoint-state/2026-05/workstreams"
  jq -n --arg pd "$proj" \
    '{workstream:"old-ws", display_name:"OldWS", project_dir:$pd, updated_at:"2026-05-09T00:00:00Z", phase:"impl"}' \
    > "$archive/checkpoint-state/2026-05/workstreams/old-ws.json"
  local out
  out=$(BATON_PROJECT_DIR="$proj" BATON_DIR="$proj/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" --list 2>&1)
  assert "LISTS-ARCHIVED: archived section present" "echo \"\$out\" | grep -q 'Archived workstreams'"
  assert "LISTS-ARCHIVED: old-ws shown with (archived) tag" "echo \"\$out\" | grep -q 'old-ws.*archived'"
  rm -rf "$proj" "$archive"
}
run_lists_archived

run_cross_project_filter() {
  local proj_a; proj_a=$(mkr); link_lib "$proj_a"
  local proj_b; proj_b=$(mkr); link_lib "$proj_b"
  local archive; archive=$(mktemp -d)
  mkdir -p "$archive/checkpoint-state/2026-05/workstreams"
  jq -n --arg pd "$proj_a" \
    '{workstream:"a-ws", display_name:"A", project_dir:$pd, updated_at:"2026-05-09T00:00:00Z", phase:"impl"}' \
    > "$archive/checkpoint-state/2026-05/workstreams/a-ws.json"
  local out
  out=$(BATON_PROJECT_DIR="$proj_b" BATON_DIR="$proj_b/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" --list 2>&1)
  assert "CROSS-PROJECT: A's workstream NOT shown when listing in B" \
    "! echo \"\$out\" | grep -q 'a-ws'"
  assert "CROSS-PROJECT: B sees empty-state message" \
    "echo \"\$out\" | grep -q 'No active or recently-archived'"
  rm -rf "$proj_a" "$proj_b" "$archive"
}
run_cross_project_filter

run_empty_state() {
  local proj; proj=$(mkr); link_lib "$proj"
  local archive; archive=$(mktemp -d)
  local out
  out=$(BATON_PROJECT_DIR="$proj" BATON_DIR="$proj/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" --list 2>&1)
  assert "EMPTY-STATE: hint message present" \
    "echo \"\$out\" | grep -q 'No active or recently-archived workstreams. Start a new session or see docs/install.md.'"
  rm -rf "$proj" "$archive"
}
run_empty_state

run_archive_recovery() {
  local proj; proj=$(mkr); link_lib "$proj"
  local archive; archive=$(mktemp -d)
  mkdir -p "$archive/checkpoint-state/2026-05/workstreams" "$archive/progress/2026-05"
  echo "# progress body" > "$archive/progress/2026-05/progress-rec-ws.md"
  jq -n --arg pd "$proj" --arg pf "$proj/.baton/progress/progress-rec-ws.md" \
    '{workstream:"rec-ws", display_name:"Rec", project_dir:$pd, updated_at:"2026-05-09T00:00:00Z", progress_file:$pf, phase:"impl"}' \
    > "$archive/checkpoint-state/2026-05/workstreams/rec-ws.json"
  USER=u CLAUDE_TERMINAL_ID=REC BATON_PROJECT_DIR="$proj" BATON_DIR="$proj/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" rec-ws 2>/dev/null
  local rc=$?
  assert "ARCHIVE-RECOVERY: rebind exits 0" "[ $rc -eq 0 ]"
  assert "ARCHIVE-RECOVERY: workstream record restored" \
    "[ -f '$proj/.baton/workstreams/rec-ws.json' ]"
  assert "ARCHIVE-RECOVERY: progress file restored" \
    "[ -s '$proj/.baton/progress/progress-rec-ws.md' ]"
  rm -rf "$proj" "$archive"
}
run_archive_recovery

run_rebind_bumps_timestamp() {
  local proj; proj=$(mkr); link_lib "$proj"
  local archive; archive=$(mktemp -d)
  jq -n --arg pd "$proj" \
    '{workstream:"bump-ws", display_name:"B", project_dir:$pd, updated_at:"2026-01-01T00:00:00Z", phase:"impl"}' \
    > "$proj/.baton/workstreams/bump-ws.json"
  USER=u CLAUDE_TERMINAL_ID=BMP BATON_PROJECT_DIR="$proj" BATON_DIR="$proj/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" bump-ws 2>/dev/null
  local new_ts; new_ts=$(jq -r '.updated_at' "$proj/.baton/workstreams/bump-ws.json")
  assert "REBIND-BUMPS: updated_at moved past 2026-01-01" \
    "[ \"$new_ts\" \\> \"2026-01-01T00:00:00Z\" ]"
  rm -rf "$proj" "$archive"
}
run_rebind_bumps_timestamp

run_cli_escape_hatch() {
  # CLI is invokable directly with no Claude Code env wrapping
  local proj; proj=$(mkr); link_lib "$proj"
  local archive; archive=$(mktemp -d)
  local rc
  BATON_PROJECT_DIR="$proj" BATON_DIR="$proj/.baton" \
    BATON_ARCHIVE_DIR="$archive" \
    bash "$RESUME" --list >/dev/null 2>&1
  rc=$?
  assert "CLI-ESCAPE-HATCH: --list exits 0 with no Claude env" "[ $rc -eq 0 ]"
  rm -rf "$proj" "$archive"
}
run_cli_escape_hatch

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
