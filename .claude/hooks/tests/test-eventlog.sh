#!/usr/bin/env bash
# test-eventlog.sh - E24-T1: eventlog::stream drops malformed lines (CC20).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$REPO_ROOT/lib/eventlog.sh"
passed=0; failed=0
assert_eq(){ [ "$1" = "$2" ] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - expected [$2] got [$1]"; }; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/log.jsonl"
# Build a corrupt log: valid, blank, whitespace-only, NUL-bytes, valid.
printf '%s\n' '{"event":"a","n":1}' > "$F"
printf '\n' >> "$F"
printf '   \n' >> "$F"
printf '\0\0\0\0\0\0\0\0\n' >> "$F"
printf '%s\n' '{"event":"b","n":2}' >> "$F"
# Sanity: a naive single-file jq stream ABORTS on this file (proves the bug the helper fixes).
naive=$(jq -r '.event' "$F" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$naive" "1" "naive jq aborts at the NUL line (only first record seen)"
# eventlog::stream recovers BOTH valid records, in order, and nothing else.
out="$(eventlog::stream "$F")"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "two valid records emitted"
assert_eq "$(printf '%s\n' "$out" | jq -rs '[.[].event]|join(",")')" "a,b" "order preserved, malformed dropped"
# stdin mode (no file args) behaves identically.
assert_eq "$(eventlog::stream < "$F" | wc -l | tr -d ' ')" "2" "stdin mode drops malformed lines"
# multi-file: concatenate two logs.
printf '%s\n' '{"event":"c","n":3}' > "$TMP/log2.jsonl"
assert_eq "$(eventlog::stream "$F" "$TMP/log2.jsonl" | wc -l | tr -d ' ')" "3" "multi-file concatenates valid records"
# empty/missing file → no output, no crash.
: > "$TMP/empty.jsonl"
assert_eq "$(eventlog::stream "$TMP/empty.jsonl" | wc -l | tr -d ' ')" "0" "empty file yields nothing"
echo "passed=$passed failed=$failed"; [ "$failed" -eq 0 ]
