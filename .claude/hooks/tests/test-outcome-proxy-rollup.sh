#!/usr/bin/env bash
# test-outcome-proxy-rollup.sh - TDD harness for tools/outcome-proxy-rollup.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_STATE="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi
}
assert_float_eq() {
  local label="$1" actual="$2" expected="$3" tol="${4:-0.0001}"
  local ok
  ok=$(awk -v a="$actual" -v e="$expected" -v t="$tol" 'BEGIN{d=a-e; if(d<0) d=-d; print (d<t)?"ok":"fail"}')
  if [ "$ok" = "ok" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label (actual=$actual expected=$expected)" >&2; fi
}

FIXTURE_DIR="$SCRIPT_DIR/fixtures/outcome-proxies"
ROLLUP="$REPO_ROOT/tools/outcome-proxy-rollup.sh"

# ── Step 1: executability ──────────────────────────────────────────────────
assert 'rollup script exists' "[ -f '$ROLLUP' ]"
assert 'rollup script is executable' "[ -x '$ROLLUP' ]"

# ── Step 3: set up transcript fixtures at test-time ───────────────────────
TRANS_DIR="$FIXTURE_DIR/rollup-transcripts"
mkdir -p "$TRANS_DIR/main"
# sess-clean: no compact_boundary lines → subset=clean
printf '' > "$TRANS_DIR/main/sess-clean.jsonl"
# sess-fired: one compact_boundary line → subset=fired
printf '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50}}}\n' > "$TRANS_DIR/main/sess-fired.jsonl"
printf '{"compact_boundary":true}\n' >> "$TRANS_DIR/main/sess-fired.jsonl"

EVENTS="$FIXTURE_DIR/rollup-events.jsonl"
PROJECTS_STATE="$FIXTURE_DIR/rollup-projects-state.json"

# ── Step 5: per-subkind aggregation assertions ─────────────────────────────
OUT=$("$ROLLUP" --log "$EVENTS" --projects-state "$PROJECTS_STATE" \
  --transcripts-dir "$TRANS_DIR" --json 2>/dev/null)

assert 'output is valid JSON' "printf '%s' '$OUT' | jq . >/dev/null 2>&1"

# code_execution: 3 session-keyed clean-subset events (success=t,t,f) → 2/3 ≈ 0.6667
RATE=$(printf '%s' "$OUT" | jq -r '.headline.baton.code_execution.success_rate // "null"')
assert 'headline.baton.code_execution.n=3' \
  "[ \"$(printf '%s' "$OUT" | jq -r '.headline.baton.code_execution.n')\" = '3' ]"
assert_float_eq 'headline.baton.code_execution.success_rate≈0.6667' "$RATE" "0.6666666666666666" "1e-9"

# retry: similarity={0.8,0.9} → mean=0.85
RETRY_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.retry.mean // "null"')
assert_float_eq 'headline.baton.retry.mean=0.85' "$RETRY_MEAN" "0.85" "1e-9"
assert 'headline.baton.retry.n=2' \
  "[ \"$(printf '%s' "$OUT" | jq -r '.headline.baton.retry.n')\" = '2' ]"

# follow_up: single slug-keyed aggregate event, mean_turns=12 - qualifies for headline (CC12 ternary)
FOLLOW_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.follow_up.mean // "null"')
assert_float_eq 'headline.baton.follow_up.mean=12' "$FOLLOW_MEAN" "12" "1e-9"

# commit_survival: single slug-keyed aggregate event, survival_fraction=0.75 - qualifies for headline
SURV_MEAN=$(printf '%s' "$OUT" | jq -r '.headline.baton.commit_survival.mean // "null"')
assert_float_eq 'headline.baton.commit_survival.mean=0.75' "$SURV_MEAN" "0.75" "1e-9"

# compact must NOT appear in headline (only fired-subset events, decomposition-only per CC12)
assert 'headline does not include compact method' \
  "printf '%s' '$OUT' | jq -e '(.headline | has(\"compact\")) | not' >/dev/null"

# fired decomposition: 2 events under sess-fired, success={t,f} → 0.5
FIRED_RATE=$(printf '%s' "$OUT" | jq -r '.decomposition.compact.fired.code_execution.success_rate // "null"')
assert_float_eq 'decomposition.compact.fired.code_execution.success_rate=0.5' "$FIRED_RATE" "0.5" "1e-9"
assert 'decomposition.compact.fired.code_execution.n=2' \
  "[ \"$(printf '%s' "$OUT" | jq -r '.decomposition.compact.fired.code_execution.n')\" = '2' ]"

# clean-subset decomposition for checkpoint (session-keyed events)
CLEAN_RATE=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.code_execution.success_rate // "null"')
assert_float_eq 'decomposition.baton.clean.code_execution.success_rate≈0.6667' "$CLEAN_RATE" "0.6666666666666666" "1e-9"
assert 'decomposition.baton.clean.code_execution.n=3' \
  "[ \"$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.code_execution.n')\" = '3' ]"
CLEAN_RETRY_MEAN=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.retry.mean // "null"')
assert_float_eq 'decomposition.baton.clean.retry.mean=0.85' "$CLEAN_RETRY_MEAN" "0.85" "1e-9"
assert 'decomposition.baton.clean.retry.n=2' \
  "[ \"$(printf '%s' "$OUT" | jq -r '.decomposition.baton.clean.retry.n')\" = '2' ]"

# aggregate-subset decomposition for checkpoint (slug-keyed T4a/T4b events)
AGG_FOLLOW=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.aggregate.follow_up.mean // "null"')
assert_float_eq 'decomposition.baton.aggregate.follow_up.mean=12' "$AGG_FOLLOW" "12" "1e-9"
AGG_SURV=$(printf '%s' "$OUT" | jq -r '.decomposition.baton.aggregate.commit_survival.mean // "null"')
assert_float_eq 'decomposition.baton.aggregate.commit_survival.mean=0.75' "$AGG_SURV" "0.75" "1e-9"

# ── Step 6: CC15 retry-intent status states ────────────────────────────────
# (a) No status file → retry_status=triage, ranking_includes_retry=false
OUT_NO_STATUS=$("$ROLLUP" --log "$EVENTS" --projects-state "$PROJECTS_STATE" \
  --transcripts-dir "$TRANS_DIR" --status-file "$TMP_STATE/nonexistent.json" --json 2>/dev/null)
assert 'no-status-file → retry_status=triage' \
  "[ \"$(printf '%s' "$OUT_NO_STATUS" | jq -r '.retry_status')\" = 'triage' ]"
assert 'no-status-file → ranking_includes_retry=false' \
  "printf '%s' '$OUT_NO_STATUS' | jq -e '.ranking_includes_retry == false' >/dev/null"

# (b) supplementary → ranking_includes_retry=false
printf '{"status":"supplementary"}' > "$TMP_STATE/status-supp.json"
OUT_SUPP=$("$ROLLUP" --log "$EVENTS" --projects-state "$PROJECTS_STATE" \
  --transcripts-dir "$TRANS_DIR" --status-file "$TMP_STATE/status-supp.json" --json 2>/dev/null)
assert 'supplementary → retry_status=supplementary' \
  "[ \"$(printf '%s' "$OUT_SUPP" | jq -r '.retry_status')\" = 'supplementary' ]"
assert 'supplementary → ranking_includes_retry=false' \
  "printf '%s' '$OUT_SUPP' | jq -e '.ranking_includes_retry == false' >/dev/null"

# (c) load_bearing → ranking_includes_retry=true
printf '{"status":"load_bearing"}' > "$TMP_STATE/status-lb.json"
OUT_LB=$("$ROLLUP" --log "$EVENTS" --projects-state "$PROJECTS_STATE" \
  --transcripts-dir "$TRANS_DIR" --status-file "$TMP_STATE/status-lb.json" --json 2>/dev/null)
assert 'load_bearing → retry_status=load_bearing' \
  "[ \"$(printf '%s' "$OUT_LB" | jq -r '.retry_status')\" = 'load_bearing' ]"
assert 'load_bearing → ranking_includes_retry=true' \
  "printf '%s' '$OUT_LB' | jq -e '.ranking_includes_retry == true' >/dev/null"

# ── Step 7: TODO marker count = exactly 2 ────────────────────────────────
TODO_COUNT=$(grep -c 'TODO(E16-followup)' "$ROLLUP" 2>/dev/null || echo 0)
assert 'exactly 2 TODO(E16-followup) markers' "[ '$TODO_COUNT' = '2' ]"

# ── CC20: malformed-line (NUL) tolerance - BOTH routed reads survive ─────
# Build a NUL-corrupted log so a project_boundary AND an outcome_proxy record
# both FOLLOW the NUL. line-69 (SESSION_META from project_boundary) and line-80
# (outcome_proxy aggregation) must each still see their post-NUL record.
NUL_LOG="$TMP_STATE/nul-events.jsonl"
{
  printf '%s\n' '{"ts":"2026-05-26T09:00:00Z","schema_version":1,"event":"project_boundary","data":{"slug":"slug-clean","kind":"start","workstream":"main","terminal_id":"term-pre","session_id":"sess-pre","description":""}}'
  printf '%s\n' '{"ts":"2026-05-26T09:01:00Z","schema_version":1,"event":"outcome_proxy","data":{"subkind":"code_execution","success":true,"runner":"pytest","exit_code":0,"session_id":"sess-pre"}}'
  printf '\0\0\0\n'
  # Post-NUL project_boundary: session-keyed meta must register despite the NUL.
  printf '%s\n' '{"ts":"2026-05-26T09:02:00Z","schema_version":1,"event":"project_boundary","data":{"slug":"slug-clean","kind":"start","workstream":"main","terminal_id":"term-post","session_id":"sess-postnul","description":""}}'
  # Post-NUL outcome_proxy keyed to the post-NUL session: must aggregate under checkpoint/clean.
  printf '%s\n' '{"ts":"2026-05-26T09:03:00Z","schema_version":1,"event":"outcome_proxy","data":{"subkind":"code_execution","success":true,"runner":"pytest","exit_code":0,"session_id":"sess-postnul"}}'
} > "$NUL_LOG"
NUL_OUT=$(bash "$ROLLUP" --log "$NUL_LOG" --projects-state "$PROJECTS_STATE" --transcripts-dir /nonexistent --json 2>/dev/null)
assert 'NUL: output is valid JSON' "printf '%s' '$NUL_OUT' | jq . >/dev/null 2>&1"
# line-80: both pre- and post-NUL code_execution events counted → n=2 under checkpoint headline.
assert 'NUL: line-80 outcome_proxy read sees post-NUL record (code_execution n=2)' \
  "printf '%s' '$NUL_OUT' | jq -e '.headline.baton.code_execution.n == 2' >/dev/null"
# line-69: post-NUL session resolves via SESSION_META → method baton, never 'unknown'.
assert 'NUL: line-69 project_boundary read registers post-NUL session (no unknown method)' \
  "printf '%s' '$NUL_OUT' | jq -e '.headline | has(\"unknown\") | not' >/dev/null"

# ── Step 7: Production-shape regression ──────────────────────────────────
# T4 event with slug-only (no session_id, no terminal_id) MUST resolve to its real method, NOT 'unknown'.
rm -f "$TMP_STATE/prod-test.jsonl"
printf '%s\n' '{"ts":"2026-05-26T11:00:00Z","schema_version":1,"event":"outcome_proxy","data":{"subkind":"follow_up","slug":"slug-clean","n_sessions":1,"n_terminals":1,"mean_turns_per_session":5,"total_turns":5}}' > "$TMP_STATE/prod-test.jsonl"
out=$(bash "$REPO_ROOT/tools/outcome-proxy-rollup.sh" --log "$TMP_STATE/prod-test.jsonl" --projects-state "$REPO_ROOT/.claude/hooks/tests/fixtures/outcome-proxies/rollup-projects-state.json" --transcripts-dir /nonexistent --json)
assert 'production-shape T4 event resolves slug→method, NOT unknown' "echo '$out' | jq -e '.headline.baton.follow_up.n == 1' >/dev/null"
assert 'production-shape T4 event does NOT collapse to unknown method' "echo '$out' | jq -e '.headline | has(\"unknown\") | not' >/dev/null"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
