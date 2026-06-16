#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TOOL="$_SD/tools/cost-sweep-corpus.sh"

PASS=0; FAIL=0
assert() { local name="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/projects/ws-A" "$TMPROOT/projects/ws-B"
# Isolate the summary-tokens auto-derivation: point it at directories with no progress files so it returns the 2500 default.
export BATON_PROGRESS_DIR="$TMPROOT/no-prog" BATON_ARCHIVE_DIR="$TMPROOT/no-arch"

write_t() {
  local path="$1" turns="$2" cr="$3" cc="$4" inp="$5" out="$6" i
  : > "$path"
  for ((i=0;i<turns;i++)); do
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
      "$inp" "$out" "$cr" "$cc" >> "$path"
  done
}
write_t "$TMPROOT/projects/ws-A/sess-1.jsonl" 6 0 5000 500 1500
write_t "$TMPROOT/projects/ws-A/sess-2.jsonl" 4 1000 0 500 1500
write_t "$TMPROOT/projects/ws-B/sess-3.jsonl" 5 5000 1000 500 1500

out=$(bash "$TOOL" --help 2>&1); rc=$?
assert 'help exits 0' "[ \"$rc\" = '0' ]"
assert 'help shows usage line' "printf '%s' \"\$out\" | grep -q 'Usage: cost-sweep-corpus.sh'"

rc=0; bash "$TOOL" --corpus /no/such/path 2>/dev/null || rc=$?
assert 'missing corpus exits non-zero' "[ \"$rc\" -ne 0 ]"

out=$(bash "$TOOL" --corpus "$TMPROOT/projects" 2>&1)
assert 'human output names tool' "printf '%s' \"\$out\" | grep -q 'cost-sweep-corpus'"
assert 'human output has THRESHOLD column' "printf '%s' \"\$out\" | grep -q 'THRESHOLD'"
assert 'human output has MEDIAN column' "printf '%s' \"\$out\" | grep -q 'MEDIAN'"
assert 'human output has MEAN column' "printf '%s' \"\$out\" | grep -q 'MEAN'"
assert 'human output has P95 column' "printf '%s' \"\$out\" | grep -q 'P95'"
assert 'human output has IQR column' "printf '%s' \"\$out\" | grep -q 'IQR'"
assert 'human output has COUNT column' "printf '%s' \"\$out\" | grep -q 'COUNT'"
assert 'human output reports n=3 transcripts' "printf '%s' \"\$out\" | grep -qE 'transcripts:[ ]*3'"
assert 'human output has TYPICAL-BEST line' "printf '%s' \"\$out\" | grep -q 'TYPICAL-BEST'"
assert 'human output includes CC6 disclaimer' "printf '%s' \"\$out\" | grep -q 'Token counts are an estimate'"

out=$(bash "$TOOL" --corpus "$TMPROOT/projects" --json 2>&1)
assert 'json parses' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'json schema_version == 3' "printf '%s' \"\$out\" | jq -e '.schema_version == 3' >/dev/null"
assert 'json transcripts length 3' "printf '%s' \"\$out\" | jq -e '.transcripts | length == 3' >/dev/null"
assert 'json per-record fields' "printf '%s' \"\$out\" | jq -e '.transcripts[0] | has(\"path\") and has(\"workspace\") and has(\"session_id\") and has(\"best_threshold\") and has(\"per_threshold\")' >/dev/null"
assert 'json aggregates type' "printf '%s' \"\$out\" | jq -e '.aggregates | type == \"object\"' >/dev/null"
assert 'json typical_best.median' "printf '%s' \"\$out\" | jq -e '.typical_best.median | (type==\"number\" or type==\"null\")' >/dev/null"
assert 'json typical_best.mode' "printf '%s' \"\$out\" | jq -e '.typical_best.mode | (type==\"number\" or type==\"null\")' >/dev/null"
assert 'json method dim' "printf '%s' \"\$out\" | jq -e '.method == \"baton-threshold\"' >/dev/null"
assert 'json includes disclaimer' "printf '%s' \"\$out\" | jq -e '.disclaimer | type == \"string\"' >/dev/null"

rc=0; bash "$TOOL" --self-check 2>&1 >/dev/null || rc=$?
assert 'self-check exits 0' "[ \"$rc\" = '0' ]"

SINGLE="$TMPROOT/single"
mkdir -p "$SINGLE/ws-X"
# Use a prefix large enough (cache_read=280000) so fill% > 28 at turn 1 and the
# checkpoint actually fires at T=28; this is what exercises sg_in_rate on the
# cross-model assertion below. With a tiny prefix no checkpoint fires and the
# cross-model arm collapses to identical values - see plan-content awareness.
write_t "$SINGLE/ws-X/only-1.jsonl" 5 280000 0 500 1500
agg_28=$(bash "$TOOL" --corpus "$SINGLE" --json | jq -r '.aggregates["28"].median')
direct_28=$(bash "$_SD/tools/cost-compare.sh" --transcript "$SINGLE/ws-X/only-1.jsonl" --json 2>/dev/null | jq -r '.thresholds["28"]')
assert 'single-transcript identity: agg median == cost-compare T=28 (exact)' "[ -n \"$agg_28\" ] && [ -n \"$direct_28\" ] && LC_ALL=C awk -v a=\"$agg_28\" -v b=\"$direct_28\" 'BEGIN{exit !(a==b || (a-b<0.000005 && b-a<0.000005))}'"

out=$(bash "$TOOL" --corpus "$TMPROOT/projects" --limit 2 --json | jq '.transcripts | length')
assert 'limit caps transcripts processed' "[ \"\$out\" = '2' ]"

out=$(bash "$TOOL" --corpus "$TMPROOT/projects" --workspace-include 'ws-A' --json | jq '.transcripts | length')
assert 'workspace-include keeps only ws-A' "[ \"\$out\" = '2' ]"

# Cross-model sg_in_rate: when --summary-model differs from --model, the
# aggregator must charge the summary model's base_in rate (parity with
# cost-compare.sh's same-flag behavior).
out_same=$(bash "$TOOL" --corpus "$SINGLE" --json --model claude-sonnet-4-6 | jq -r '.aggregates["28"].median')
out_cross=$(bash "$TOOL" --corpus "$SINGLE" --json --model claude-sonnet-4-6 --summary-model claude-opus-4-7 | jq -r '.aggregates["28"].median')
assert 'cross-model summary-model strictly increases T=28 cost' "LC_ALL=C awk -v a=\"$out_same\" -v b=\"$out_cross\" 'BEGIN{exit !((b+0) > (a+0))}'"

EMPTY="$TMPROOT/empty"
mkdir -p "$EMPTY"
rc=0; out=$(bash "$TOOL" --corpus "$EMPTY" 2>&1) || rc=$?
assert 'empty corpus exits non-zero' "[ \"$rc\" -ne 0 ]"
assert 'empty corpus prints clear message' "printf '%s' \"\$out\" | grep -qi 'no transcripts'"

assert 'no network in tools/cost-sweep-corpus.sh' "! grep -E 'curl|wget|\\bnc\\b|/dev/tcp' \"$TOOL\""
assert 'tool parses' "bash -n \"$TOOL\""

# ---- T2 / F16: CI method tests (studentized+log default; BCa sensitivity fallback) ----
# Fixture: varied token counts per session so bootstrap resamples have non-zero variance.
# CI attaches under .strata[stratum_key].per_method[arm].ci (workshop auto-stratifies by workspace).
FIXTURE_CORPUS="$TMPROOT/ci-corpus"
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

ci_out=$(BATON_PROGRESS_DIR="$TMPROOT/no-prog" BATON_ARCHIVE_DIR="$TMPROOT/no-arch" SEED=42 bash "$TOOL" --corpus "$FIXTURE_CORPUS" --rigor workshop --json 2>/dev/null)
if [ -n "$ci_out" ]; then
  ci_methods=$(printf '%s' "$ci_out" | jq -r '[.strata[]?.per_method[]? | select(.ci) | .ci.method] | unique | @json' 2>/dev/null || echo '[]')
  assert 'workshop default CI method = studentized+log' \
    "printf '%s' '$ci_methods' | jq -e '. == [\"studentized+log\"]' >/dev/null 2>&1"
else
  FAIL=$((FAIL+1)); printf 'FAIL: workshop --json returned empty\n'
fi

bca_out=$(BATON_PROGRESS_DIR="$TMPROOT/no-prog" BATON_ARCHIVE_DIR="$TMPROOT/no-arch" SEED=42 bash "$TOOL" --corpus "$FIXTURE_CORPUS" --rigor workshop --ci-method bca --json 2>/dev/null)
if [ -n "$bca_out" ]; then
  assert 'F16: --ci-method bca: all CI methods == bca' \
    "printf '%s' \"\$bca_out\" | jq -e '[.strata[]?.per_method[]? | select(.ci) | .ci.method] | all(. == \"bca\")' >/dev/null 2>&1"
else
  FAIL=$((FAIL+1)); printf 'FAIL: --ci-method bca --json returned empty\n'
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
