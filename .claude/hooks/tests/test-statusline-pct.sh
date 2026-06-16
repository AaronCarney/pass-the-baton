#!/usr/bin/env bash
# test-statusline-pct.sh - coverage for assets/baton-pct.sh color modes.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SHIM="$REPO/assets/baton-pct.sh"
PASS=0; FAIL=0
_assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SESSION_ID=test123
PCT_FILE="/tmp/claude-context-pct-${SESSION_ID}"
DONE_FILE="/tmp/baton-done-${SESSION_ID}"
trap 'rm -f "$PCT_FILE" "$DONE_FILE"; rm -rf "$TMP"' EXIT

# Assertion 1: default (unset) keeps plain text - current behavior must NOT change
echo 42 > "$PCT_FILE"
unset BATON_STATUSLINE_COLOR_MODE
out=$(bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:42%' "$out" 'default unset = plain text'

# Assertion 2: explicit =off behaves same as unset
out=$(BATON_STATUSLINE_COLOR_MODE=off bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:42%' "$out" 'explicit off = plain text'

# Assertion 3: =solid threshold hardcoded at 80 (iter-3: env var dropped - no dashboard consumer).
echo 85 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[31mCTX:85%\033[0m' "$out" 'solid >=80 = red'
echo 50 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:50%' "$out" 'solid <80 = plain'
# Boundary at exactly 80 must trigger.
echo 80 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[31mCTX:80%\033[0m' "$out" 'solid =80 boundary = red'

# Assertion 4: =bands ranges with exact boundaries.
echo 30 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[32mCTX:30%\033[0m' "$out" 'bands 30 = green'
# Iter-3: lower-boundary PCT=0 - bands green branch lower edge.
echo 0 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[32mCTX:0%\033[0m' "$out" 'bands 0 = green (lower boundary)'
# Iter-4: just-below-yellow boundary catches -gt 49 vs -ge 50 off-by-one.
echo 49 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[32mCTX:49%\033[0m' "$out" 'bands 49 = green (just below yellow boundary)'
echo 50 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[33mCTX:50%\033[0m' "$out" 'bands 50 boundary = yellow'
echo 60 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[33mCTX:60%\033[0m' "$out" 'bands 60 = yellow'
echo 80 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[31mCTX:80%\033[0m' "$out" 'bands 80 boundary = red'
echo 90 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[31mCTX:90%\033[0m' "$out" 'bands 90 = red'

# Assertion 5: DONE_FILE present overrides everything.
touch "$DONE_FILE"
out=$(bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:DONE' "$out" 'DONE_FILE present = CTX:DONE'
out=$(BATON_STATUSLINE_COLOR_MODE=bands bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:DONE' "$out" 'DONE_FILE overrides color mode'
rm -f "$DONE_FILE"

# Assertion 6: missing PCT_FILE → exit 0, no output.
rm -f "$PCT_FILE"
out=$(bash "$SHIM" "$SESSION_ID")
_assert_eq '' "$out" 'missing PCT file = empty output'

# Assertion 7: empty PCT_FILE → exit 0, no output.
: > "$PCT_FILE"
out=$(bash "$SHIM" "$SESSION_ID")
_assert_eq '' "$out" 'empty PCT file = empty output'

# Assertion 8: unknown mode = behaves as off.
echo 90 > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=garbage bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:90%' "$out" 'unknown mode = plain (safe fallback)'

# Assertion 9: non-numeric PCT → empty/plain output, no integer-comparison crash.
echo 'abc' > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
case "$out" in *abc*) PASS=$((PASS+1));; '') PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); printf 'FAIL: non-numeric PCT crash, got %q\n' "$out" >&2;; esac

# Assertion 10: negative PCT → plain (negative is not >= threshold, no crash).
echo '-5' > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
_assert_eq 'CTX:-5%' "$out" 'negative PCT = plain (no crash, no color)'

# Assertion 11: overflow PCT (120) → still emits, no integer-overflow crash.
echo '120' > "$PCT_FILE"
out=$(BATON_STATUSLINE_COLOR_MODE=solid bash "$SHIM" "$SESSION_ID")
_assert_eq $'\033[31mCTX:120%\033[0m' "$out" 'overflow PCT 120 = red (no crash)'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
