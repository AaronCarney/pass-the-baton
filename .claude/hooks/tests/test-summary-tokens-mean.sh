#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
mkdir -p "$XDG_STATE_HOME/baton"
source "$REPO/lib/summary-tokens-mean.sh"
PASS=0; FAIL=0
_aeq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }
STATE="$XDG_STATE_HOME/baton/summary-tokens-mean.json"

# Case 1: read returns empty when no state file.
_aeq '' "$(_stm::read)" 'no state = empty'

# Case 2: update creates state file with n=1, mean=tokens.
_stm::update 4000 hash-A
state=$(cat "$STATE")
_aeq '1' "$(printf '%s' "$state" | jq -r .n)" 'n=1 after first update'
_aeq '4000' "$(printf '%s' "$state" | jq -r .mean)" 'mean=4000 after first update'
_aeq 'hash-A' "$(printf '%s' "$state" | jq -r .skill_hash)" 'skill_hash captured'

# Case 3: second update with same hash → running mean.
_stm::update 2000 hash-A
state=$(cat "$STATE")
_aeq '2' "$(printf '%s' "$state" | jq -r .n)" 'n=2 after second update'
_aeq '3000' "$(printf '%s' "$state" | jq -r .mean)" 'mean=(4000+2000)/2=3000'

# Case 4: update with new hash → reset to n=1.
_stm::update 5000 hash-B
state=$(cat "$STATE")
_aeq '1' "$(printf '%s' "$state" | jq -r .n)" 'n reset on hash change'
_aeq '5000' "$(printf '%s' "$state" | jq -r .mean)" 'mean reset to new value'
_aeq 'hash-B' "$(printf '%s' "$state" | jq -r .skill_hash)" 'hash updated'

# Case 5: _stm::read returns current mean.
_aeq '5000' "$(_stm::read)" 'read returns current mean'

# Case 6: flock concurrency - two concurrent updates yield n=2, no lost updates.
rm -f "$STATE"
_stm::update 1000 conc & PID1=$!
_stm::update 1000 conc & PID2=$!
wait "$PID1"; wait "$PID2"
n_after=$(jq -r .n "$STATE")
_aeq '2' "$n_after" 'concurrent updates → n=2 (flock holds)'

# Case 7: corrupt state-file → next update reinitializes cleanly.
printf 'this is not json' > "$STATE"
_stm::update 7000 hash-C
state=$(cat "$STATE")
_aeq '1' "$(printf '%s' "$state" | jq -r .n)" 'corrupt state → next update resets n=1'
_aeq '7000' "$(printf '%s' "$state" | jq -r .mean)" 'corrupt state → mean reflects new tokens'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
