#!/usr/bin/env bash
# Tests for lib/recommend-outcome-extract.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/lib/recommend-outcome-extract.sh"
FIXTURES="$REPO_ROOT/.claude/hooks/tests/fixtures/recommend"

pass=0; fail=0

check() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  PASS: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label - got='$got' want='$want'"
    fail=$((fail + 1))
  fi
}

# shellcheck source=/dev/null
source "$LIB"

echo "=== recommend_outcome::winner (PRIMARY rule) ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-real.json")
check "outcome-real winner is 'unknown'" "$result" "unknown"

echo "=== recommend_outcome::winner (FALLBACK rule) ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-no-success-rate.json")
check "no-success-rate winner is 'compact' (n=12 > n=7)" "$result" "compact"

echo "=== recommend_outcome::per_method ==="
result=$(recommend_outcome::per_method "$FIXTURES/outcome-real.json")
# Should return the .headline object verbatim
keys=$(echo "$result" | jq -r 'keys[]')
check "per_method returns object with 'unknown' key" "$keys" "unknown"

echo "=== recommend_outcome::winner (empty headline) ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-thin.json")
check "thin outcome returns null" "$result" "null"

echo "=== recommend_outcome::is_insufficient ==="
check "29 days → insufficient" "$(recommend_outcome::is_insufficient 29)" "true"
check "30 days → sufficient" "$(recommend_outcome::is_insufficient 30)" "false"
check "0 days → insufficient" "$(recommend_outcome::is_insufficient 0)" "true"
check "100 days → sufficient" "$(recommend_outcome::is_insufficient 100)" "false"

echo "=== recommend_outcome::post_e16_days (CC_NOW fixed) ==="
# Create temp events log with earliest outcome_proxy at 2026-05-04T00:00:00Z
TMPEVENTS=$(mktemp)
cat > "$TMPEVENTS" <<'EOF'
{"event":"session_start","ts":"2026-05-04T00:00:00Z","session_id":"s1"}
{"event":"outcome_proxy","ts":"2026-05-04T00:00:00Z","session_id":"s1","method":"compact"}
{"event":"outcome_proxy","ts":"2026-05-10T00:00:00Z","session_id":"s2","method":"compact"}
{"event":"session_end","ts":"2026-05-29T00:00:00Z","session_id":"s1"}
EOF
export CC_NOW="2026-05-29"
days=$(recommend_outcome::post_e16_days "$TMPEVENTS")
check "post_e16_days == 25 (CC_NOW=2026-05-29, earliest=2026-05-04)" "$days" "25"
rm -f "$TMPEVENTS"
unset CC_NOW

echo "=== CC20: malformed-line (NUL) tolerance (post_e16_days :49) ==="
# Inject a NUL so the ONLY outcome_proxy record FOLLOWS it; :49 (jq -rs over
# $events_log) must still compute ts_min over the post-NUL record.
NULEVENTS=$(mktemp)
{
  printf '%s\n' '{"event":"session_start","ts":"2026-05-04T00:00:00Z","session_id":"s0"}'
  printf '\0\0\0\n'
  printf '%s\n' '{"event":"outcome_proxy","ts":"2026-05-04T00:00:00Z","session_id":"s1","method":"compact"}'
} > "$NULEVENTS"
export CC_NOW="2026-05-29"
nul_days=$(recommend_outcome::post_e16_days "$NULEVENTS")
check "NUL: post_e16_days == 25 over post-NUL outcome_proxy (:49)" "$nul_days" "25"
rm -f "$NULEVENTS"
unset CC_NOW

echo "=== TIE-BREAK PRIMARY (lex-first) ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-tie.json")
check "tie on success_rate → lex-first = 'clear-only'" "$result" "clear-only"

echo "=== TIE-BREAK FALLBACK (lex-first) ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-tie-fallback.json")
check "tie on sum-of-n → lex-first = 'clear-only'" "$result" "clear-only"

echo "=== PER-ELEMENT // 0 BINDING ==="
result=$(recommend_outcome::winner "$FIXTURES/outcome-partial-n.json")
# compact: retry.n=5 + code_execution.n=0 = 5; none: retry.n=3 → compact wins
check "partial-n: compact (n=5) beats none (n=3)" "$result" "compact"

echo "=== PRODUCER_CONTRACT ==="
ROLLUP_EVENTS="$REPO_ROOT/.claude/hooks/tests/fixtures/outcome-proxies/rollup-events.jsonl"
TMPOUT=$(mktemp)
bash "$REPO_ROOT/tools/outcome-proxy-rollup.sh" --log "$ROLLUP_EVENTS" --json 2>/dev/null > "$TMPOUT"
per_method=$(recommend_outcome::per_method "$TMPOUT")
rm -f "$TMPOUT"
key_count=$(echo "$per_method" | jq 'keys | length')
if [[ "$key_count" -gt 0 ]]; then
  echo "  PASS: PRODUCER_CONTRACT_OUTCOME_OK"
  pass=$((pass + 1))
else
  echo "  FAIL: producer per_method returned empty object"
  fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
