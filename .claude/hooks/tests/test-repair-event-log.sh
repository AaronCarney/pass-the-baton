#!/usr/bin/env bash
# test-repair-event-log.sh - E24-T4: backup-first event-log repair tool (CC20).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL="$REPO_ROOT/tools/repair-event-log.sh"
source "$REPO_ROOT/lib/eventlog.sh"
passed=0; failed=0
assert_eq(){ [ "$1" = "$2" ] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - expected [$2] got [$1]"; }; }
assert_ne(){ [ "$1" != "$2" ] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - both [$1]"; }; }
ok(){ passed=$((passed+1)); }
bad(){ failed=$((failed+1)); echo "FAIL: $1"; }
md5(){ md5sum "$1" | cut -d' ' -f1; }

TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# A corrupt fixture: valid, blank, whitespace-only, NUL-bytes, valid.
make_corrupt(){
  printf '%s\n' '{"event":"a","n":1}' > "$1"
  printf '\n' >> "$1"
  printf '   \n' >> "$1"
  printf '\0\0\0\0\0\0\0\0\n' >> "$1"
  printf '%s\n' '{"event":"b","n":2}' >> "$1"
}

# ---------------------------------------------------------------------------
# (a) --dry-run: reports dropped>=1, file byte-identical, NO backup written.
# ---------------------------------------------------------------------------
D="$TMP/a"; mkdir -p "$D"; F="$D/log.jsonl"; make_corrupt "$F"
before="$(md5 "$F")"
out="$(bash "$TOOL" --dry-run "$F" 2>&1)"; rc=$?
assert_eq "$rc" "0" "dry-run exits 0"
dropped="$(printf '%s\n' "$out" | grep -oiE 'dropped[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
[ "${dropped:-0}" -ge 1 ] && ok || bad "dry-run reports dropped>=1 (got [$dropped] in: $out)"
assert_eq "$(md5 "$F")" "$before" "dry-run leaves file byte-identical"
assert_eq "$(ls "$D"/log.jsonl.bak-* 2>/dev/null | wc -l | tr -d ' ')" "0" "dry-run writes NO backup"

# ---------------------------------------------------------------------------
# (b) real run: backup == ORIGINAL; log rewritten to ONLY valid records
#     (eventlog::stream of result == result); correct kept/dropped counts.
# ---------------------------------------------------------------------------
D="$TMP/b"; mkdir -p "$D"; F="$D/log.jsonl"; make_corrupt "$F"
orig="$(md5 "$F")"
out="$(bash "$TOOL" "$F" 2>&1)"; rc=$?
assert_eq "$rc" "0" "real run exits 0"
bak="$(ls "$D"/log.jsonl.bak-* 2>/dev/null | head -1)"
[ -n "$bak" ] && ok || bad "real run creates a .bak-* backup"
assert_eq "$(md5 "$bak")" "$orig" "backup equals the ORIGINAL bytes"
# repaired log is a fixed point of eventlog::stream
assert_eq "$(eventlog::stream "$F" | md5sum | cut -d' ' -f1)" "$(md5 "$F")" "repaired log is eventlog::stream fixed point"
assert_eq "$(eventlog::stream "$F" | jq -rs '[.[].event]|join(",")')" "a,b" "only valid records kept, order preserved"
kept="$(printf '%s\n' "$out" | grep -oiE 'kept[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "${kept:-X}" "2" "summary reports kept=2"
dropped="$(printf '%s\n' "$out" | grep -oiE 'dropped[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "${dropped:-X}" "3" "summary reports dropped=3"

# ---------------------------------------------------------------------------
# (c) repaired log mode 0600.
# ---------------------------------------------------------------------------
assert_eq "$(stat -c '%a' "$F")" "600" "repaired log mode 0600"

# ---------------------------------------------------------------------------
# (d) backup-failure path: read-only dir → exit non-zero, original NOT truncated.
# ---------------------------------------------------------------------------
D="$TMP/d"; mkdir -p "$D"; F="$D/log.jsonl"; make_corrupt "$F"
before="$(md5 "$F")"
chmod a-w "$D"
out="$(bash "$TOOL" "$F" 2>&1)"; rc=$?
chmod u+w "$D"
assert_ne "$rc" "0" "backup-failure exits non-zero"
assert_eq "$(md5 "$F")" "$before" "backup-failure does NOT truncate original"

# ---------------------------------------------------------------------------
# (e) clean-input no-false-drop: zero corrupt lines → dropped==0, kept bytes ==.
# ---------------------------------------------------------------------------
D="$TMP/e"; mkdir -p "$D"; F="$D/log.jsonl"
printf '%s\n' '{"event":"a","n":1}' > "$F"
printf '%s\n' '{"event":"b","n":2}' >> "$F"
clean_before="$(md5 "$F")"
out="$(bash "$TOOL" "$F" 2>&1)"; rc=$?
assert_eq "$rc" "0" "clean run exits 0"
dropped="$(printf '%s\n' "$out" | grep -oiE 'dropped[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "${dropped:-X}" "0" "clean input drops 0"
assert_eq "$(md5 "$F")" "$clean_before" "clean input kept byte-identical"

# ---------------------------------------------------------------------------
# (f) resolve-failure: missing log path → non-zero, no backup / no truncate.
# ---------------------------------------------------------------------------
D="$TMP/f"; mkdir -p "$D"; F="$D/missing.jsonl"
out="$(bash "$TOOL" "$F" 2>&1)"; rc=$?
assert_ne "$rc" "0" "missing log exits non-zero"
assert_eq "$(ls "$D"/missing.jsonl.bak-* 2>/dev/null | wc -l | tr -d ' ')" "0" "missing log creates no backup"
[ -e "$F" ] && bad "missing log must not be created" || ok

# ---------------------------------------------------------------------------
# (g) unterminated final line: valid, NUL, valid-WITHOUT-trailing-newline.
#     total must count the last line (awk NR), so the NUL drop is reported,
#     not masked to dropped=0 by wc -l undercounting.
# ---------------------------------------------------------------------------
D="$TMP/g"; mkdir -p "$D"; F="$D/log.jsonl"
printf '%s\n' '{"event":"a","n":1}' > "$F"
printf '\0\0\0\0\n' >> "$F"
printf '%s' '{"event":"b","n":2}' >> "$F"   # no trailing newline
out="$(bash "$TOOL" --dry-run "$F" 2>&1)"; rc=$?
assert_eq "$rc" "0" "unterminated-final dry-run exits 0"
dropped="$(printf '%s\n' "$out" | grep -oiE 'dropped[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "${dropped:-X}" "1" "unterminated final line: NUL drop reported (not masked to 0)"

echo "passed=$passed failed=$failed"; [ "$failed" -eq 0 ]
