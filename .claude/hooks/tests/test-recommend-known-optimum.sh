#!/usr/bin/env bash
# test-recommend-known-optimum.sh - fixture test: compact is best on all three dimensions.
# Fixture: corpus-known-optimum (6 sessions: sess-1..3 clean, sess-4..6 with compact_boundary)
#   - cost winner: compact (lowest per_arm_per_subset usd_total via --cost-json fixture)
#   - time winner: compact (sessions with compact_boundary inferred as compact by TTC)
#   - outcome winner: compact (clean-subset sessions tagged method=compact via projects.json)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Setup temp HOME with corpus ──
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/.claude/projects/main"
cp "$FX/corpus-known-optimum/main"/*.jsonl "$TMP_HOME/.claude/projects/main/"
mkdir -p "$TMP_HOME/baton"
printf '{"proj-ko": {"method": "compact"}}\n' > "$TMP_HOME/baton/projects.json"

# ── Resolve __REPO__ sentinel in cost-json at runtime so corpus paths exist ──
sed "s#__REPO__#$REPO#g" "$FX/cost-known-optimum.json" > "$TMP_HOME/cost-known-optimum.json"

# ── Run recommend.sh ──
result=$(HOME="$TMP_HOME" \
  BATON_PROJECTS_STATE="$TMP_HOME/baton/projects.json" \
  BATON_CORPUS_DIR="$TMP_HOME/.claude/projects" \
  bash "$REPO/tools/recommend.sh" \
    --cost-json "$TMP_HOME/cost-known-optimum.json" \
    --log "$FX/events-known-optimum.jsonl" \
    --json 2>/dev/null)
rc=$?

[ "$rc" -eq 0 ] && _pass "exit 0" || _fail "exit 0 (got $rc)"

cost_w=$(printf '%s' "$result" | jq -r '.winners.cost // "null"')
time_w=$(printf '%s' "$result" | jq -r '.winners.time // "null"')
outcome_w=$(printf '%s' "$result" | jq -r '.winners.outcome // "null"')

[ "$cost_w" = "compact" ]    && _pass "winners.cost==compact"    || _fail "winners.cost==compact (got: $cost_w)"
[ "$time_w" = "compact" ]    && _pass "winners.time==compact"    || _fail "winners.time==compact (got: $time_w)"
[ "$outcome_w" = "compact" ] && _pass "winners.outcome==compact" || _fail "winners.outcome==compact (got: $outcome_w)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
