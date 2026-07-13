#!/bin/bash
# Unit tests for find_workstream_by_session_id (crash-recovery reverse lookup).
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0; FAILED_CASES=()
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); echo "  PASS  $name";
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"; fi
}
seed_ws() {
  local dir="$1" ws="$2" sid="$3" ts="$4"
  jq -n --arg ws "$ws" --arg sid "$sid" --arg ts "$ts" \
    '{workstream:$ws, display_name:$ws, progress_file:"", phase:"unknown", updated_at:$ts, session_id:$sid}' \
    > "$dir/workstreams/${ws}.json"
}
echo "## find_workstream_by_session_id"

t_match() {
  local tr; tr=$(mktemp -d); mkdir -p "$tr/workstreams"
  seed_ws "$tr" "ws-a" "sid-123" "2026-07-11T00:00:00Z"
  local got; got=$(find_workstream_by_session_id "$tr" "sid-123")
  assert "match: returns ws-a" "[ '$got' = 'ws-a' ]"
  rm -rf "$tr"
}
t_match

t_nomatch() {
  local tr; tr=$(mktemp -d); mkdir -p "$tr/workstreams"
  seed_ws "$tr" "ws-a" "sid-123" "2026-07-11T00:00:00Z"
  local got rc; got=$(find_workstream_by_session_id "$tr" "sid-999"); rc=$?
  assert "no-match: empty output" "[ -z '$got' ]"
  assert "no-match: rc 1" "[ $rc -eq 1 ]"
  rm -rf "$tr"
}
t_nomatch

t_emptysid() {
  local tr; tr=$(mktemp -d); mkdir -p "$tr/workstreams"
  seed_ws "$tr" "ws-a" "" "2026-07-11T00:00:00Z"
  local got rc; got=$(find_workstream_by_session_id "$tr" ""); rc=$?
  assert "empty-sid: rc 1" "[ $rc -eq 1 ]"
  assert "empty-sid: empty output" "[ -z '$got' ]"
  rm -rf "$tr"
}
t_emptysid

t_newest() {
  local tr; tr=$(mktemp -d); mkdir -p "$tr/workstreams"
  seed_ws "$tr" "ws-old" "sid-dup" "2026-07-10T00:00:00Z"
  seed_ws "$tr" "ws-new" "sid-dup" "2026-07-11T12:00:00Z"
  local got; got=$(find_workstream_by_session_id "$tr" "sid-dup")
  assert "multiple: newest updated_at wins (ws-new)" "[ '$got' = 'ws-new' ]"
  rm -rf "$tr"
}
t_newest

t_legacy() {
  local tr; tr=$(mktemp -d); mkdir -p "$tr/workstreams"
  jq -n '{workstream:"ws-legacy", display_name:"x", progress_file:"", phase:"unknown", updated_at:"2026-07-11T00:00:00Z"}' \
    > "$tr/workstreams/ws-legacy.json"
  local got rc; got=$(find_workstream_by_session_id "$tr" "sid-123"); rc=$?
  assert "legacy: no session_id field -> rc 1" "[ $rc -eq 1 ] && [ -z '$got' ]"
  rm -rf "$tr"
}
t_legacy

echo ""
echo "find_workstream_by_session_id: $PASS pass, $FAIL fail"
[ ${#FAILED_CASES[@]} -eq 0 ] || printf '  FAILED: %s\n' "${FAILED_CASES[@]}"
[ "$FAIL" -eq 0 ]
