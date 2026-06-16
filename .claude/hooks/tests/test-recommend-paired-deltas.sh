#!/usr/bin/env bash
# Tests for lib/recommend-paired-deltas.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURES="$REPO/.claude/hooks/tests/fixtures/recommend"
LIB="$REPO/lib/recommend-paired-deltas.sh"

source "$LIB"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── T1: all_pairs returns object with compact-vs-clear-only key ───────────────
# Key is alphabetical: clear-only sorts before compact => clear-only-vs-compact
result=$(SEED=42 recommend_paired::all_pairs "$FIXTURES")
key=$(echo "$result" | jq -r 'keys[]' 2>/dev/null | grep -c 'compact\|clear-only' || true)
[ "$key" -ge 1 ] && _pass "T1: compact/clear-only pair key present" \
  || _fail "T1: compact/clear-only pair key missing; got: $result"

# Determine actual pair key for subsequent tests.
PAIR_KEY=$(echo "$result" | jq -r 'keys[0]' 2>/dev/null)

# ── T2: n_paired == 5 ─────────────────────────────────────────────────────────
n_paired=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.n_paired' 2>/dev/null)
[ "$n_paired" = "5" ] && _pass "T2: n_paired==5" \
  || _fail "T2: n_paired expected 5, got: $n_paired (key=$PAIR_KEY)"

# ── T3: mean_diff is a number (compact has lower cost so log-diff < 0 for compact-first pair) ──
mean_diff=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.mean_diff' 2>/dev/null)
is_num=$(echo "$mean_diff" | python3 -c "import sys; float(sys.stdin.read()); print(1)" 2>/dev/null || echo 0)
[ "$is_num" = "1" ] && _pass "T3: mean_diff is a number" \
  || _fail "T3: mean_diff not a number, got: $mean_diff"

# ── T4: ci object has ci_lower and ci_upper keys ─────────────────────────────
ci_lower=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.ci.ci_lower' 2>/dev/null)
ci_upper=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.ci.ci_upper' 2>/dev/null)
[ "$ci_lower" != "null" ] && [ "$ci_upper" != "null" ] \
  && _pass "T4: ci has ci_lower and ci_upper" \
  || _fail "T4: ci missing lower/upper; lower=$ci_lower upper=$ci_upper"

# ── T5: wilcoxon block has statistic and p_value ─────────────────────────────
stat=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.wilcoxon.statistic' 2>/dev/null)
pval=$(echo "$result" | jq -r --arg k "$PAIR_KEY" '.[$k].clean.wilcoxon.p_value' 2>/dev/null)
[ "$stat" != "null" ] && [ "$pval" != "null" ] \
  && _pass "T5: wilcoxon has statistic and p_value" \
  || _fail "T5: wilcoxon missing statistic/p_value; stat=$stat pval=$pval"

# ── T6: single arm dir returns '{}' (no crash) ───────────────────────────────
TMP_SINGLE=$(mktemp -d)
cp "$FIXTURES/arm-compact.jsonl" "$TMP_SINGLE/"
single_result=$(SEED=42 recommend_paired::all_pairs "$TMP_SINGLE" 2>/dev/null)
rm -rf "$TMP_SINGLE"
[ "$single_result" = "{}" ] && _pass "T6: single arm returns '{}'" \
  || _fail "T6: single arm expected '{}', got: $single_result"

# ── T7: zero slug overlap gives n_paired==0 ───────────────────────────────────
TMP_NO_OVERLAP=$(mktemp -d)
printf '{"slug":"a1","value":0.001}\n{"slug":"a2","value":0.002}\n' > "$TMP_NO_OVERLAP/arm-x.jsonl"
printf '{"slug":"b1","value":0.001}\n{"slug":"b2","value":0.002}\n' > "$TMP_NO_OVERLAP/arm-y.jsonl"
no_overlap_result=$(SEED=42 recommend_paired::all_pairs "$TMP_NO_OVERLAP" 2>/dev/null)
rm -rf "$TMP_NO_OVERLAP"
np0=$(echo "$no_overlap_result" | jq -r 'to_entries[0].value.clean.n_paired' 2>/dev/null)
[ "$np0" = "0" ] && _pass "T7: zero overlap gives n_paired==0" \
  || _fail "T7: zero overlap expected n_paired==0, got: $np0; result=$no_overlap_result"

# ── T8: DETERMINISM - byte-equal output across two runs ─────────────────────
out1=$(SEED=42 recommend_paired::all_pairs "$FIXTURES" 2>/dev/null)
out2=$(SEED=42 recommend_paired::all_pairs "$FIXTURES" 2>/dev/null)
[ "$out1" = "$out2" ] && _pass "T8: deterministic output" \
  || _fail "T8: non-deterministic output"

# ── T9: C-018 SENTINEL-FAIL CONTRACT ─────────────────────────────────────────
TMP_SENTINEL=$(mktemp -d)
cp "$FIXTURES/arm-compact.jsonl" "$TMP_SENTINEL/"
cp "$FIXTURES/arm-clear-only.jsonl" "$TMP_SENTINEL/"
sentinel_rc=0
sentinel_stderr=$(REPLAY_HARNESS_NONZERO_ARMS=0 SEED=42 recommend_paired::all_pairs "$TMP_SENTINEL" 2>&1 >/dev/null) || sentinel_rc=$?
rm -rf "$TMP_SENTINEL"
if [ "$sentinel_rc" -eq 1 ] && echo "$sentinel_stderr" | grep -q 'all-zero replay-harness output - degenerate corpus'; then
  _pass "T9: sentinel-fail rc=1 + correct stderr"
else
  _fail "T9: sentinel-fail; rc=$sentinel_rc stderr='$sentinel_stderr'"
fi

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
