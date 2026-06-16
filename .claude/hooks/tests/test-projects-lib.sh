#!/usr/bin/env bash
# Test harness for lib/projects.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export CLAUDE_PROJECT_DIR="$REPO_ROOT"
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT

passed=0; failed=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" == "$expected" ]]; then passed=$((passed+1));
  else failed=$((failed+1)); echo "FAIL: $msg - expected [$expected], got [$actual]"; fi
}
assert_file_exists() {
  local path="$1" msg="$2"
  if [[ -f "$path" ]]; then passed=$((passed+1));
  else failed=$((failed+1)); echo "FAIL: $msg - file missing: $path"; fi
}
assert_ge() {
  local actual="$1" expected="$2" msg="$3"
  if (( actual >= expected )); then passed=$((passed+1));
  else failed=$((failed+1)); echo "FAIL: $msg - expected >= $expected, got $actual"; fi
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/projects.sh"

# === Test: state directory bootstraps ===
projects::ensure_state_dir
assert_file_exists "$XDG_STATE_HOME/baton/projects/.keep" \
  "projects::ensure_state_dir creates state dir with sentinel"

# === Test: mark_start_state ===
rm -rf "$XDG_STATE_HOME/baton/projects"
projects::ensure_state_dir
projects::mark_start_state slug-foo ws-bar 'optional description'
assert_file_exists "$(projects::state_dir)/slug-foo.json" \
  "mark_start_state writes per-slug state file"
assert_eq "$(jq -r .slug "$(projects::state_dir)/slug-foo.json")" "slug-foo" \
  "state file slug matches"
assert_eq "$(jq -r .workstream "$(projects::state_dir)/slug-foo.json")" "ws-bar" \
  "state file workstream matches"
assert_eq "$(jq -r .description "$(projects::state_dir)/slug-foo.json")" "optional description" \
  "state file carries description"
assert_eq "$(jq -r '.ended_at // "null"' "$(projects::state_dir)/slug-foo.json")" "null" \
  "state file has no ended_at on start"

set +e
projects::mark_start_state slug-foo ws-bar 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "2" "double mark_start_state on same slug → rc=2 (state)"

# === Test: single-active arc guard + method/terminal_id persistence ===
rm -rf "$XDG_STATE_HOME/baton/projects"
projects::ensure_state_dir
projects::mark_start_state ga ws-x '' term-guard m1
set +e; projects::mark_start_state gb ws-x '' term-guard m2; rc=$?; set -e
assert_eq "$rc" "2" "lib: second open arc on same terminal -> rc=2"
if [[ ! -f "$(projects::state_dir)/gb.json" ]]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: refused start must not write gb.json"; fi
assert_eq "$(jq -r .terminal_id "$(projects::state_dir)/ga.json")" "term-guard" "lib: terminal_id persisted"
assert_eq "$(jq -r .method "$(projects::state_dir)/ga.json")" "m1" "lib: method persisted"

# === Test: mark_end_state ===
rm -rf "$XDG_STATE_HOME/baton/projects"
projects::ensure_state_dir
projects::mark_start_state slug-bar ws-baz
projects::mark_end_state slug-bar success 'optional note'
assert_eq "$(jq -r .status "$(projects::state_dir)/slug-bar.json")" "success" "mark_end_state writes status"
assert_eq "$(jq -r '.ended_at | type' "$(projects::state_dir)/slug-bar.json")" "string" "mark_end_state sets ended_at"
assert_eq "$(jq -r '.notes | length' "$(projects::state_dir)/slug-bar.json")" "1" "mark_end_state appends note"

set +e
projects::mark_end_state slug-never-started success 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "2" "mark_end_state on unknown slug → rc=2 (state)"

set +e
projects::mark_end_state slug-bar bogus 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "mark_end_state with bogus status → rc=1 (arg)"

# === Test: list + show ===
rm -rf "$XDG_STATE_HOME/baton/projects"
projects::ensure_state_dir
projects::mark_start_state slug-a ws-1
projects::mark_start_state slug-b ws-1
projects::mark_end_state slug-a success

active_slugs="$(projects::list active | sort | tr '\n' ' ')"
assert_eq "$active_slugs" "slug-b " "list active returns only un-ended slugs"

all_slugs="$(projects::list all | sort | tr '\n' ' ')"
assert_eq "$all_slugs" "slug-a slug-b " "list all returns every slug"

show_slug="$(projects::show slug-a | jq -r .slug)"
assert_eq "$show_slug" "slug-a" "show returns matching state JSON"

set +e
projects::show slug-nope 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "2" "show on unknown slug → rc=2 (state)"

# === Test: emit_event ===
rm -rf "$XDG_STATE_HOME/baton"
mkdir -p "$XDG_STATE_HOME/baton"
log="$XDG_STATE_HOME/baton/hook-events.jsonl"

projects::emit_event start slug-x ws-1 term-abc '' '' >/dev/null
assert_file_exists "$log" "emit_event writes to hook-events.jsonl"
last="$(tail -1 "$log")"
assert_eq "$(echo "$last" | jq -r .event)" "project_boundary" "event name set"
assert_eq "$(echo "$last" | jq -r .schema_version)" "1" "envelope stamps top-level schema_version=1"
assert_eq "$(echo "$last" | jq -r .data.kind)" "start" "kind=start"
assert_eq "$(echo "$last" | jq -r .data.slug)" "slug-x" "slug captured"
assert_eq "$(echo "$last" | jq 'has("schema_version") and (.data | has("schema_version") | not)')" "true" \
  "schema_version lives on envelope only, NOT on data payload"

projects::emit_event end slug-x ws-1 term-abc success 'wrap note' >/dev/null
last="$(tail -1 "$log")"
assert_eq "$(echo "$last" | jq -r .data.kind)" "end" "kind=end"
assert_eq "$(echo "$last" | jq -r .data.status)" "success" "end status captured"

set +e
projects::emit_event bogus slug-x ws-1 term-abc '' '' 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "emit_event with bogus kind → rc=1 (arg)"

# === Test: active_for_workstream + idle_days ===
rm -rf "$XDG_STATE_HOME/baton/projects"
projects::ensure_state_dir
projects::mark_start_state slug-w1a ws-1
sleep 1  # ensure distinct started_at timestamps for the tiebreak test
projects::mark_start_state slug-w2a ws-2
projects::mark_end_state slug-w1a success
sleep 1
projects::mark_start_state slug-w1b ws-1

assert_eq "$(projects::active_for_workstream ws-1)" "slug-w1b" \
  "active_for_workstream returns most-recent active in ws-1 by started_at"
assert_eq "$(projects::active_for_workstream ws-2)" "slug-w2a" \
  "active_for_workstream returns active in ws-2"
assert_eq "$(projects::active_for_workstream ws-empty)" "" \
  "active_for_workstream returns empty for unknown ws"

# Backdate started_at by 10 days using JSON edit (not file mtime).
old_iso="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)"
tmp_json="$(jq --arg s "$old_iso" '.started_at = $s' "$(projects::state_dir)/slug-w2a.json")"
printf '%s\n' "$tmp_json" > "$(projects::state_dir)/slug-w2a.json"
assert_ge "$(projects::idle_days ws-2)" 8 "idle_days reports >= 8 for backdated started_at"

echo "Results: $passed passed, $failed failed"
exit $(( failed == 0 ? 0 : 1 ))
