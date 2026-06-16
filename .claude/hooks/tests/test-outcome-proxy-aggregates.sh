#!/usr/bin/env bash
# test-outcome-proxy-aggregates.sh - per-proxy aggregates on T6 fixture corpus (T7c)
# Asserts per-method, per-subset expected values from the pinned fixture.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/outcome-proxies"
ROLLUP="$REPO_ROOT/tools/outcome-proxy-rollup.sh"

TMP_STATE="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE"' EXIT

PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi
}
assert_float_eq() {
  local label="$1" actual="$2" expected="$3" tol="${4:-1e-9}"
  local ok
  ok=$(awk -v a="$actual" -v e="$expected" -v t="$tol" \
    'BEGIN{d=a-e; if(d<0)d=-d; print (d<t)?"ok":"fail"}')
  if [ "$ok" = "ok" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $label (actual=$actual expected=$expected)" >&2
  fi
}

TRANS_DIR="$FIXTURE_DIR/rollup-transcripts"

# ── Ensure transcript fixtures exist (T6 writes these; replicate if absent) ─
mkdir -p "$TRANS_DIR/main"
if [ ! -s "$TRANS_DIR/main/sess-clean.jsonl" ]; then
  printf '' > "$TRANS_DIR/main/sess-clean.jsonl"
fi
if [ ! -s "$TRANS_DIR/main/sess-fired.jsonl" ]; then
  printf '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}\n' \
    > "$TRANS_DIR/main/sess-fired.jsonl"
  printf '{"compact_boundary":true}\n' >> "$TRANS_DIR/main/sess-fired.jsonl"
fi

EVENTS="$FIXTURE_DIR/rollup-events.jsonl"
PROJECTS_STATE="$FIXTURE_DIR/rollup-projects-state.json"

# ── Run rollup; point status-file at non-existent path → triage defaults ──
OUT=$(bash "$ROLLUP" \
  --log "$EVENTS" \
  --projects-state "$PROJECTS_STATE" \
  --transcripts-dir "$TRANS_DIR" \
  --status-file "$TMP_STATE/nonexistent.json" \
  --json 2>/dev/null)

assert 'rollup output is valid JSON' "printf '%s' '$OUT' | jq . >/dev/null 2>&1"

# ── Headline (clean subset only) ──────────────────────────────────────────
CE_RATE=$(printf '%s' "$OUT" | jq -r '.headline.baton.code_execution.success_rate // "null"')
CE_N=$(printf '%s' "$OUT" | jq -r '.headline.baton.code_execution.n // "null"')
assert_float_eq 'headline.baton.code_execution.success_rate≈0.6667' \
  "$CE_RATE" "0.6666666666666666"
assert 'headline.baton.code_execution.n==3' \
  "[ \"$CE_N\" = '3' ]"

RETRY_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.retry.mean // "null"')
RETRY_N=$(printf '%s' "$OUT" | jq -r '.headline.baton.retry.n // "null"')
assert_float_eq 'headline.baton.retry.mean≈0.85' "$RETRY_MEAN" "0.85"
assert 'headline.baton.retry.n==2' "[ \"$RETRY_N\" = '2' ]"

FOLLOW_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.follow_up.mean // "null"')
assert_float_eq 'headline.baton.follow_up.mean==12' "$FOLLOW_MEAN" "12"

SURV_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.commit_survival.mean // "null"')
assert_float_eq 'headline.baton.commit_survival.mean==0.75' "$SURV_MEAN" "0.75"

# ── Decomposition ─────────────────────────────────────────────────────────
CLEAN_CE_RATE=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.code_execution.success_rate // "null"')
assert_float_eq 'decomp.baton.clean.code_execution.success_rate≈0.6667' \
  "$CLEAN_CE_RATE" "0.6666666666666666"

CLEAN_RETRY=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.retry.mean // "null"')
assert_float_eq 'decomp.baton.clean.retry.mean≈0.85' "$CLEAN_RETRY" "0.85"

FIRED_CE_RATE=$(printf '%s' "$OUT" | jq -r '.decomposition.compact.fired.code_execution.success_rate // "null"')
FIRED_CE_N=$(printf '%s' "$OUT" | jq -r '.decomposition.compact.fired.code_execution.n // "null"')
assert_float_eq 'decomp.compact.fired.code_execution.success_rate==0.5' "$FIRED_CE_RATE" "0.5"
assert 'decomp.compact.fired.code_execution.n==2' "[ \"$FIRED_CE_N\" = '2' ]"

# ── CC12: compact method absent from headline ─────────────────────────────
assert 'CC12: headline does not contain compact method' \
  "printf '%s' '$OUT' | jq -e '(.headline | has(\"compact\")) | not' >/dev/null"

# ── CC15: no retry-intent-status.json → retry_status=triage, ranking_includes_retry=false ──
RS=$(printf '%s' "$OUT" | jq -r '.retry_status // "null"')
# jq // treats false as falsy; use tostring to get the literal "false"
RI=$(printf '%s' "$OUT" | jq -r 'if has("ranking_includes_retry") then (.ranking_includes_retry | tostring) else "null" end')
assert 'CC15: retry_status==triage' "[ \"$RS\" = 'triage' ]"
assert 'CC15: ranking_includes_retry==false' "[ \"$RI\" = 'false' ]"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
