#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export CLAUDE_PROJECT_DIR="$REPO_ROOT"
trap 'rm -rf "$TMP_STATE"' EXIT

passed=0; failed=0
assert_contains() { echo "$1" | grep -q -- "$2" && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - output did not contain [$2]"; }; }
assert_notcontains() { ! echo "$1" | grep -q -- "$2" && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - output unexpectedly contained [$2]"; }; }

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/projects.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/.claude/hooks/lib/session-start-helpers.sh"

# === Test: prompt fires when no active project AND idle_days >= 7 ===
projects::ensure_state_dir
projects::mark_start_state slug-old ws-stale
projects::mark_end_state slug-old success
old_iso="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)"
tmp_json="$(jq --arg s "$old_iso" '.started_at = $s' "$(projects::state_dir)/slug-old.json")"
printf '%s\n' "$tmp_json" > "$(projects::state_dir)/slug-old.json"
out="$(session_start::maybe_project_prompt ws-stale)"
assert_contains "$out" 'mark-start' 'prompt fires for stale ws with no active project'

# === Test: prompt does NOT fire when active project exists ===
projects::mark_start_state slug-fresh ws-active
out="$(session_start::maybe_project_prompt ws-active)"
assert_notcontains "$out" 'mark-start' 'prompt suppressed when ws has active project'

# === Test: prompt does NOT fire when ws is fresh ===
projects::mark_start_state slug-recent ws-recent
projects::mark_end_state slug-recent success
out="$(session_start::maybe_project_prompt ws-recent)"
assert_notcontains "$out" 'mark-start' 'prompt suppressed when ws is recent'

# === Test: empty ws id is no-op ===
out="$(session_start::maybe_project_prompt '')"
assert_notcontains "$out" 'mark-start' 'empty ws id is no-op'

# === Test: brand-new ws (no prior projects) triggers nudge ===
# idle_days returns 999999 when no state files match the workstream;
# the nudge fires on first session for any never-tracked workstream.
out="$(session_start::maybe_project_prompt ws-brand-new)"
assert_contains "$out" 'mark-start' 'prompt fires for ws with zero prior projects'

echo "Results: $passed passed, $failed failed"
exit $(( failed == 0 ? 0 : 1 ))
