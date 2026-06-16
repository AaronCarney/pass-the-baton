#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-retry-density.sh"
TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so emit-and-assert paths collect.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0
assert() { local label="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi; }

assert 'hook is executable' "[ -x \"$HOOK\" ]"

# === three-prompt sequence test ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
FIX="$REPO_ROOT/.claude/hooks/tests/fixtures/outcome-proxies/retry-density-prompts.jsonl"
while IFS= read -r line; do
  echo "$line" | jq -c '. + {session_id: "sess-a"}' | bash "$HOOK"
done < "$FIX"

event_count=$(wc -l < "$BATON_EVENT_LOG" 2>/dev/null || echo 0)
assert '3 events emitted' "[ $event_count -eq 3 ]"
sim1=$(sed -n '1p' "$BATON_EVENT_LOG" | jq -r '.data.similarity')
sim2=$(sed -n '2p' "$BATON_EVENT_LOG" | jq -r '.data.similarity')
sim3=$(sed -n '3p' "$BATON_EVENT_LOG" | jq -r '.data.similarity')
assert 'event 1: sim=0 (no priors)' "awk -v s=\"$sim1\" 'BEGIN{exit !(s==0)}'"
assert 'event 2: sim > 0.5 (near-dup)' "awk -v s=\"$sim2\" 'BEGIN{exit !(s>0.5)}'"
assert 'event 3: sim < 0.3 (unrelated)' "awk -v s=\"$sim3\" 'BEGIN{exit !(s<0.3)}'"
assert 'event 1: n_prior=0' "sed -n '1p' \"$BATON_EVENT_LOG\" | jq -e '.data.n_prior_prompts == 0' >/dev/null"
assert 'event 3: n_prior=2' "sed -n '3p' \"$BATON_EVENT_LOG\" | jq -e '.data.n_prior_prompts == 2' >/dev/null"
assert 'no prompt field in any event' "! grep -q '\"prompt\":' \"$BATON_EVENT_LOG\""
unset BATON_OUTCOME_PROXIES

# === consent-off test ===
rm -f "$BATON_EVENT_LOG"
ring_file="$TMP_STATE/baton/outcome-proxies/retry-ring-sess-b.jsonl"
unset BATON_OUTCOME_PROXIES
echo '{"prompt":"hello world","session_id":"sess-b"}' | bash "$HOOK"
assert 'consent off → 0 events' "[ ! -s \"$BATON_EVENT_LOG\" ]"
assert 'consent off → no ring file' "[ ! -f \"$ring_file\" ]"

# === session_id absence: payload omits key (matches T2 code-execution pattern) ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
echo '{"prompt":"hello world without session"}' | bash "$HOOK"
assert 'session_id absent: event emitted' "[ -s \"$BATON_EVENT_LOG\" ]"
assert 'session_id absent: payload does NOT contain session_id key (omitted, not "unknown")' "jq -e '.data | (has(\"session_id\") | not)' \"$BATON_EVENT_LOG\" >/dev/null"
assert 'session_id absent: payload does NOT contain literal "unknown" sentinel' "! grep -q '\"unknown\"' \"$BATON_EVENT_LOG\""
unset BATON_OUTCOME_PROXIES

# === ring-truncation test ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
ring_file_c="$TMP_STATE/baton/outcome-proxies/retry-ring-sess-c.jsonl"
for i in $(seq 1 7); do
  echo "{\"prompt\":\"prompt number $i with unique words\",\"session_id\":\"sess-c\"}" | bash "$HOOK"
done
ring_c_count=$(wc -l < "$ring_file_c" 2>/dev/null || echo 0)
assert 'ring truncated to 5 lines' "[ $ring_c_count -eq 5 ]"
unset BATON_OUTCOME_PROXIES

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
