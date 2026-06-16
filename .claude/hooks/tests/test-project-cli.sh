#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export CLAUDE_PROJECT_DIR="$REPO_ROOT"
export CLAUDE_TERMINAL_ID="term-test-cli"
export CLAUDE_WORKSTREAM="ws-cli-test"
trap 'rm -rf "$TMP_STATE"' EXIT

passed=0; failed=0
assert_eq() { [[ "$1" == "$2" ]] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - expected [$2] got [$1]"; }; }

CLI="$REPO_ROOT/tools/project.sh"

# === Test: --help works ===
out="$(bash "$CLI" --help 2>&1)"
echo "$out" | grep -q 'mark-start' && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: --help mentions mark-start"; }

# === mark-start + start event ===
log="$TMP_STATE/baton/hook-events.jsonl"   # B1: original decl was inside the replaced region; re-declare before first use
bash "$CLI" mark-start slug-cli-1 --description 'cli test'
assert_eq "$(jq -r .slug "$TMP_STATE/baton/projects/slug-cli-1.json")" "slug-cli-1" "mark-start writes state file"
last="$(tail -1 "$log")"
assert_eq "$(echo "$last" | jq -r .data.kind)" "start" "mark-start emits kind=start"
assert_eq "$(echo "$last" | jq -r .schema_version)" "1" "envelope schema_version=1"
assert_eq "$(echo "$last" | jq -r .data.workstream)" "$CLAUDE_WORKSTREAM" "event workstream from env"

set +e; bash "$CLI" mark-start 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "1" "mark-start with no slug -> rc=1"
set +e; bash "$CLI" mark-start slug-cli-1 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "2" "mark-start with existing slug -> rc=2"
# single active arc: slug-cli-1 still open, a DIFFERENT slug is refused too
set +e; bash "$CLI" mark-start slug-second 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "2" "second mark-start on same terminal while one open -> rc=2"
[[ -f "$TMP_STATE/baton/projects/slug-second.json" ]] && { failed=$((failed+1)); echo 'FAIL: refused start must not write state'; } || passed=$((passed+1))
bash "$CLI" mark-end slug-cli-1 --status success

# === method + terminal_id captured at mark-start ===
bash "$CLI" mark-start slug-m --method '/compact' --description 'method test'
mstate="$TMP_STATE/baton/projects/slug-m.json"
assert_eq "$(jq -r .method "$mstate")" "/compact" "mark-start persists method"
assert_eq "$(jq -r .terminal_id "$mstate")" "term-test-cli" "mark-start persists terminal_id"
bash "$CLI" mark-end slug-m --status success

# === method optional -> empty string ===
bash "$CLI" mark-start slug-nomethod
assert_eq "$(jq -r .method "$TMP_STATE/baton/projects/slug-nomethod.json")" "" "method defaults to empty string"
bash "$CLI" mark-end slug-nomethod --status success

# === mark-end rc paths (each opens+closes its own arc) ===
bash "$CLI" mark-start slug-e3
set +e; bash "$CLI" mark-end slug-e3 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "1" "mark-end without --status -> rc=1"
bash "$CLI" mark-end slug-e3 --status success   # close it so the terminal is free
set +e; bash "$CLI" mark-end slug-never --status success 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "2" "mark-end on unknown slug -> rc=2"

# === list + show (single-active discipline; only slug-list-b stays open) ===
bash "$CLI" mark-start slug-list-a
bash "$CLI" mark-end slug-list-a --status success
bash "$CLI" mark-start slug-list-b
assert_eq "$(bash "$CLI" list --active | sort | tr '\n' ' ')" "slug-list-b " "list --active shows only the one open arc"
assert_eq "$(bash "$CLI" list --all | sort | tr '\n' ' ')" "slug-cli-1 slug-e3 slug-list-a slug-list-b slug-m slug-nomethod " "list --all returns every arc"
assert_eq "$(bash "$CLI" show slug-list-a | jq -r .status)" "success" "show returns state JSON"
set +e; bash "$CLI" show slug-nope 2>/dev/null; rc=$?; set -e
assert_eq "$rc" "2" "show unknown slug -> rc=2"

echo "Results: $passed passed, $failed failed"
exit $(( failed == 0 ? 0 : 1 ))
