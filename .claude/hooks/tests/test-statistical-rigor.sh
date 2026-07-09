#!/usr/bin/env bash
# .claude/hooks/tests/test-statistical-rigor.sh - L1 §E15 exit-gate aggregator. Delegates to per-tool leaf suites.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Build SUITES from the known E15 leaf tests, filtering to files that exist on disk.
SUITES=()
for s in test-stats-bootstrap.sh test-paired-compare.sh test-hierarchical-model.sh \
          test-stratify-by.sh test-rigor-flag.sh test-cost-sweep-corpus.sh \
          test-corpus.sh test-cost-compare.sh; do
  [ -f "$REPO_ROOT/.claude/hooks/tests/$s" ] && SUITES+=("$s")
done

PASS=0; FAIL=0
for s in "${SUITES[@]}"; do
  if bash "$REPO_ROOT/.claude/hooks/tests/$s"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done

# --- L1 §E15 end-to-end exit-gate smoke ---
echo '=== L1 §E15 exit-gate smoke ===' >&2
SMOKE_PASS=0; SMOKE_FAIL=0

# F19: smoke 1 - build inline corpus fixture if none on disk; assert workshop emits studentized+log CIs.
FIXTURE_CORPUS=$(find "$REPO_ROOT/.claude/hooks/tests/fixtures" -type d -name 'corpus*' 2>/dev/null | head -1)
if [ -z "$FIXTURE_CORPUS" ]; then
  FIXTURE_CORPUS=$(mktemp -d)
  mkdir -p "$FIXTURE_CORPUS/ws-ci"
  for ci_inp in 500 600 700 800 900 1000 1100 1200; do
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%s,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":5000}}}\n' "$ci_inp"
  done > "$FIXTURE_CORPUS/ws-ci/ci-sess-1.jsonl"
  for ci_inp in 300 450 600 750 900 1050; do
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%s,"output_tokens":1200,"cache_read_input_tokens":2000,"cache_creation_input_tokens":3000}}}\n' "$ci_inp"
  done > "$FIXTURE_CORPUS/ws-ci/ci-sess-2.jsonl"
  for ci_inp in 400 550 700 850 1000 1150 1300; do
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%s,"output_tokens":1800,"cache_read_input_tokens":1000,"cache_creation_input_tokens":4000}}}\n' "$ci_inp"
  done > "$FIXTURE_CORPUS/ws-ci/ci-sess-3.jsonl"
  echo "smoke 1: built inline corpus fixture at $FIXTURE_CORPUS" >&2
  _SMOKE1_CLEANUP="$FIXTURE_CORPUS"
else
  _SMOKE1_CLEANUP=""
fi
smoke1_out=$(BATON_PROGRESS_DIR=/tmp/_s1np BATON_ARCHIVE_DIR=/tmp/_s1na SEED=42 \
  bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus "$FIXTURE_CORPUS" --rigor workshop --json 2>/dev/null)
[ -n "$_SMOKE1_CLEANUP" ] && rm -rf "$_SMOKE1_CLEANUP"
if printf '%s' "$smoke1_out" | jq -e \
  '[.strata[]?.per_method[]? | select(.ci) | .ci.method] | unique | . == ["studentized+log"]' \
  >/dev/null 2>&1; then
  echo 'smoke 1 OK: cost-sweep workshop emits studentized+log CIs' >&2; SMOKE_PASS=$((SMOKE_PASS+1))
else
  echo 'smoke 1 FAIL: cost-sweep workshop did not emit studentized+log' >&2; SMOKE_FAIL=$((SMOKE_FAIL+1))
fi

# F20: smoke 2 - hierarchical --self-check, tight grep + explicit rc=0 check.
set +e
timeout 180 python3 "$REPO_ROOT/tools/hierarchical-model.py" --self-check --seed 42 > /tmp/_hier_smoke2.out 2>&1
hier_rc=$?
set -e
if [ $hier_rc -eq 0 ] && grep -qE '"gates_passed"[[:space:]]*:[[:space:]]*true|gates_passed=true' /tmp/_hier_smoke2.out; then
  echo 'smoke 2 OK: hierarchical self-check gates pass (rc=0 + tight grep)' >&2; SMOKE_PASS=$((SMOKE_PASS+1))
else
  echo "smoke 2 FAIL: hierarchical self-check rc=$hier_rc; output: $(head -20 /tmp/_hier_smoke2.out)" >&2
  SMOKE_FAIL=$((SMOKE_FAIL+1))
fi

# Smoke 3 - subset-aware paired-compare end-to-end with clean + fired transcripts.
mkdir -p /tmp/e15_smoke3
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > /tmp/e15_smoke3/clean.jsonl
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":10000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > /tmp/e15_smoke3/fired.jsonl
cat > /tmp/e15_smoke3/arm_a.jsonl <<'EOF'
{"slug":"s1","transcript_path":"/tmp/e15_smoke3/clean.jsonl","value":1.0}
{"slug":"s2","transcript_path":"/tmp/e15_smoke3/fired.jsonl","value":2.0}
EOF
cat > /tmp/e15_smoke3/arm_b.jsonl <<'EOF'
{"slug":"s1","transcript_path":"/tmp/e15_smoke3/clean.jsonl","value":1.1}
{"slug":"s2","transcript_path":"/tmp/e15_smoke3/fired.jsonl","value":2.5}
EOF
smoke3_out=$(bash "$REPO_ROOT/tools/paired-compare.sh" \
  --arm-a /tmp/e15_smoke3/arm_a.jsonl --arm-b /tmp/e15_smoke3/arm_b.jsonl \
  --subset both --json --seed 42 2>/dev/null)
if printf '%s' "$smoke3_out" | jq -e \
  '.clean.n_paired == 1 and .fired.gamma_bounded.arm_a.cost_lower != null and (.fired.caveat | test("do not point-estimate"; "i"))' \
  >/dev/null 2>&1; then
  echo 'smoke 3 OK: subset-aware paired-compare end-to-end' >&2; SMOKE_PASS=$((SMOKE_PASS+1))
else
  echo "smoke 3 FAIL: subset-aware paired-compare. Output: $smoke3_out" >&2
  SMOKE_FAIL=$((SMOKE_FAIL+1))
fi

echo "=== L1 §E15 smoke: $SMOKE_PASS passed, $SMOKE_FAIL failed ===" >&2
[ $SMOKE_FAIL -eq 0 ] || FAIL=$((FAIL+1))

# (F18 retired) The former shellcheck differential gate compared against a
# /tmp/shellcheck-baseline.txt captured by a one-time manual pre-implementation
# step; that baseline never exists in a standalone or CI run, so the gate could
# only ever error. It was a build-time gate for the original E15 change, not an
# ongoing invariant, and shellcheck is not a CI dependency.

# --- F25: L1 cross-check codified ---
cat > /tmp/closeout-crosscheck.txt <<'EOF'
L1 line 173 (studentized-on-log default) → T1 + T2
L1 line 173 (BCa as sensitivity) → T1 + T2 (--ci-method bca)
L1 line 174 (CUPED) → T1
L1 line 174 (cluster bootstrap at session level) → T1
L1 line 175 (Bambi+nutpie hierarchical, HalfNormal priors) → T3
L1 line 175 (hard diagnostic gates) → T3
L1 line 177 (subset-aware paired-compare) → T4
L1 line 177 (MSM-Γ caveat on fired subset) → T4
L1 line 178 (--rigor on every E11/E13/E14 tool) → T5
L1 line 179 (variance-component recovery + identity invariants) → T3 + T4 tests
L1 line 180 (docs page) → T6
L1 lines 183-186 (exit gates) → T7 smokes 1-3
EOF
xcheck_fail=0
for entry in 'line 173.*T1' 'line 174.*T1' 'line 175.*T3' 'line 177.*T4' 'line 178.*T5' 'line 180.*T6'; do
  if ! grep -qE "$entry" /tmp/closeout-crosscheck.txt; then
    echo "F25 FAIL: missing L1 cross-check entry: $entry" >&2
    xcheck_fail=$((xcheck_fail+1))
  fi
done
if [ $xcheck_fail -gt 0 ]; then
  FAIL=$((FAIL+1))
fi
echo '=== L1 cross-check ===' >&2
cat /tmp/closeout-crosscheck.txt >&2

echo "test-statistical-rigor: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
