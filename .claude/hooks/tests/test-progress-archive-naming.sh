#!/usr/bin/env bash
# test-progress-archive-naming.sh - the post-write archiver names each archived
# progress file with exactly one timestamp, and deletes stale scaffolds instead
# of archiving them (E5 items 2 and 3a).
#
# Usage: bash .claude/hooks/tests/test-progress-archive-naming.sh
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WT="$HOOKS_DIR/checkpoint-write-trigger.sh"

PASS=0; FAIL=0; FAILED_CASES=()
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); echo "  PASS  $name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"; fi
}

# Project skeleton + terminal/workstream state the write-trigger needs before it
# reaches the archive loop. Mirrors test-event-log-e2e.sh's stage_pending.
mkproj() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.baton/progress" "$d/.baton/workstreams" "$d/.baton/terminals" \
           "$d/share/templates" "$d/archive"
  : > "$d/share/templates/free.md"
  printf '%s' "$d"
}

stage() {
  local d="$1" sid="$2" ws="$3" term="$4"
  local th; th=$(printf '%s:%s' "${USER:-x}" "$term" | md5sum | cut -d' ' -f1)
  jq -n --arg tid "$term" --arg ws "$ws" --arg ts "2026-01-01T00:00:00Z" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    > "$d/.baton/terminals/${th}.json"
  jq -n --arg ws "$ws" --arg pd "$d" --arg ts "2026-01-01T00:00:00Z" \
    '{workstream:$ws, display_name:$ws, progress_file:"", phase:"unknown",
      updated_at:$ts, project_dir:$pd}' \
    > "$d/.baton/workstreams/${ws}.json"
  touch "/tmp/baton-pending-${sid}"
  echo "/tmp/dummy-pointer-${sid}" > "/tmp/claude-session-tracking-${sid}"
  printf '%s' "$th"
}

fire_wt() {
  local d="$1" sid="$2" term="$3" progress="$4"
  local stdin_wt
  stdin_wt=$(jq -cn --arg s "$sid" --arg c "$d" --arg f "$progress" \
    '{session_id:$s, cwd:$c, tool_name:"Write", tool_input:{file_path:$f}}')
  (
    export BATON_DIR="$d/.baton"
    export BATON_PROGRESS_DIR="$d/.baton/progress"
    export BATON_ARCHIVE_DIR="$d/archive"
    export CLAUDE_PROJECT_DIR="$d"
    export CLAUDE_TERMINAL_ID="$term"
    export BATON_EVENT_LOG_DISABLE=1
    unset AGENT_SESSION_ID
    printf '%s' "$stdin_wt" | bash "$WT" >/dev/null 2>/dev/null
  )
}

cleanup_sid() {
  rm -f "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/baton-archive-$1" \
        "/tmp/claude-session-tracking-$1" "/tmp/baton-manual-$1"
}

YM=$(date +%Y-%m)

echo "## archived progress filenames carry exactly one timestamp"

# A1: a post-190289c basename already ends in -YYYYmmdd-HHMMSS. The archiver must
# not append a second timestamp - that is the doubled datetime E5 item 2 removes.
run_a1() {
  local d; d=$(mkproj)
  local sid="sid-a1-$$" ws="arcws1" term="ATerm1"
  stage "$d" "$sid" "$ws" "$term" >/dev/null
  local th; th=$(printf '%s:%s' "${USER:-x}" "$term" | md5sum | cut -d' ' -f1)
  local prior="$d/.baton/progress/progress-${ws}-${th}-20260101-010101.md"
  local fresh="$d/.baton/progress/progress-${ws}-${th}-20260202-020202.md"
  printf '## prior\n' > "$prior"
  printf '## fresh\n' > "$fresh"
  echo "$prior" > "/tmp/baton-archive-${sid}"
  fire_wt "$d" "$sid" "$term" "$fresh"
  assert "A1: archived under its own write timestamp, unchanged" \
    "[ -f '$d/archive/progress/$YM/progress-${ws}-${th}-20260101-010101.md' ]"
  assert "A1: no second timestamp appended" \
    "[ -z \"\$(find '$d/archive/progress/$YM' -name 'progress-${ws}-${th}-20260101-010101-*.md' 2>/dev/null)\" ]"
  cleanup_sid "$sid"; rm -rf "$d"
}
run_a1

# A2: a pre-190289c legacy basename carries no timestamp. The appended one is the
# only thing keeping two of them from colliding, so it must still be appended.
# The workstream id is a real minted one (<slug>-YYYYmmdd-HHMMSS-<6 hex>, see
# context-checkpoint.sh) whose hex suffix starts with a digit: that is the shape
# that a trailing-timestamp test must not mistake for an already-stamped name.
run_a2() {
  local d; d=$(mkproj)
  local sid="sid-a2-$$" ws="main-20260514-103020-9a7bc6" term="ATerm2"
  stage "$d" "$sid" "$ws" "$term" >/dev/null
  local th; th=$(printf '%s:%s' "${USER:-x}" "$term" | md5sum | cut -d' ' -f1)
  local legacy="$d/.baton/progress/progress-${ws}-${th}.md"
  local fresh="$d/.baton/progress/progress-${ws}-${th}-20260202-020202.md"
  printf '## legacy\n' > "$legacy"
  printf '## fresh\n' > "$fresh"
  echo "$legacy" > "/tmp/baton-archive-${sid}"
  fire_wt "$d" "$sid" "$term" "$fresh"
  assert "A2: legacy basename gets a timestamp appended" \
    "[ -n \"\$(find '$d/archive/progress/$YM' -name 'progress-${ws}-${th}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].md' 2>/dev/null)\" ]"
  assert "A2: legacy file left the active directory" "[ ! -f '$legacy' ]"
  cleanup_sid "$sid"; rm -rf "$d"
}
run_a2

# A4: two checkpoints in the same second disambiguate as -<n>. That tail is still
# a write timestamp, so it must survive archiving without a second one appended.
run_a4() {
  local d; d=$(mkproj)
  local sid="sid-a4-$$" ws="main-20260514-103020-9a7bc6" term="ATerm4"
  stage "$d" "$sid" "$ws" "$term" >/dev/null
  local th; th=$(printf '%s:%s' "${USER:-x}" "$term" | md5sum | cut -d' ' -f1)
  local prior="$d/.baton/progress/progress-${ws}-${th}-20260101-010101-2.md"
  local fresh="$d/.baton/progress/progress-${ws}-${th}-20260202-020202.md"
  printf '## prior\n' > "$prior"
  printf '## fresh\n' > "$fresh"
  echo "$prior" > "/tmp/baton-archive-${sid}"
  fire_wt "$d" "$sid" "$term" "$fresh"
  assert "A4: same-second suffix archived unchanged" \
    "[ -f '$d/archive/progress/$YM/progress-${ws}-${th}-20260101-010101-2.md' ]"
  assert "A4: no second timestamp appended" \
    "[ -z \"\$(find '$d/archive/progress/$YM' -name 'progress-${ws}-${th}-20260101-010101-2-*.md' 2>/dev/null)\" ]"
  cleanup_sid "$sid"; rm -rf "$d"
}
run_a4

echo "## stale scaffolds are deleted, not archived"

# A3: a lint-blocked checkpoint leaves a .scaffold.md behind. It is regenerable
# and holds no state the progress file lacks, so it is deleted. Archiving it
# lands <base>.scaffold-<ts>.md, because basename -.md does not strip .scaffold.md.
run_a3() {
  local d; d=$(mkproj)
  local sid="sid-a3-$$" ws="arcws3" term="ATerm3"
  stage "$d" "$sid" "$ws" "$term" >/dev/null
  local th; th=$(printf '%s:%s' "${USER:-x}" "$term" | md5sum | cut -d' ' -f1)
  local stale="$d/.baton/progress/progress-${ws}-${th}-20260101-010101.scaffold.md"
  local fresh="$d/.baton/progress/progress-${ws}-${th}-20260202-020202.md"
  printf '## stale scaffold\n' > "$stale"
  printf '## fresh\n' > "$fresh"
  echo "$stale" > "/tmp/baton-archive-${sid}"
  fire_wt "$d" "$sid" "$term" "$fresh"
  assert "A3: stale scaffold removed from the active directory" "[ ! -f '$stale' ]"
  assert "A3: no scaffold reached the archive" \
    "[ -z \"\$(find '$d/archive' -name '*scaffold*' 2>/dev/null)\" ]"
  cleanup_sid "$sid"; rm -rf "$d"
}
run_a3

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
