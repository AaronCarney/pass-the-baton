#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
OUT_TMP=$(mktemp)
trap 'rm -f "$OUT_TMP" /tmp/_pc_out.txt' EXIT

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label" >&2; fi
}

# Step 1: --help / no-args gate
rc=0; bash "$REPO_ROOT/tools/paired-compare.sh" > /tmp/_pc_out.txt 2>&1 || rc=$?
assert 'no args → rc=1' "[ $rc -eq 1 ]"
assert 'usage mentions --arm-a' "grep -q -- '--arm-a' /tmp/_pc_out.txt"
assert 'usage mentions --arm-b' "grep -q -- '--arm-b' /tmp/_pc_out.txt"

# Step 5: Identity case (A == B) - migrated to .clean.* paths (F2)
A=$(mktemp); B=$(mktemp)
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf '{"slug":"s%d","value":%d.5}\n' "$i" "$i" >> "$A"
done
cp "$A" "$B"
rc=0; SEED=42 bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a "$A" --arm-b "$B" --n-resamples 1000 --seed 42 > "$OUT_TMP" 2>&1 || rc=$?
assert 'identity rc=0' "[ $rc -eq 0 ]"
assert 'identity .clean.n_paired=10' "jq -e '.clean.n_paired == 10' '$OUT_TMP' >/dev/null"
assert 'identity .clean.mean_diff=0' "jq -e '.clean.mean_diff == 0' '$OUT_TMP' >/dev/null"
assert 'identity .clean.wilcoxon p > 0.5' "jq -e '.clean.wilcoxon.p_value > 0.5' '$OUT_TMP' >/dev/null"
assert 'identity .clean.ci contains 0' "jq -e '.clean.ci.ci_lower <= 0 and .clean.ci.ci_upper >= 0' '$OUT_TMP' >/dev/null"
# L1 line 179 identity invariant: arm_a == arm_b => p > 0.5 AND CI contains 0
assert 'identity L1-179 .clean.wilcoxon.p_value > 0.5' "jq -e '.clean.wilcoxon.p_value > 0.5' '$OUT_TMP' >/dev/null"
assert 'identity L1-179 .clean.ci contains 0' "jq -e '.clean.ci.ci_lower <= 0 and .clean.ci.ci_upper >= 0' '$OUT_TMP' >/dev/null"
rm -f "$A" "$B"

# Step 6: Non-identity test (B = A + 5 shift) - migrated to .clean.* paths (F2)
A=$(mktemp); B=$(mktemp)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  printf '{"slug":"s%d","value":%d.0}\n' "$i" "$i" >> "$A"
  printf '{"slug":"s%d","value":%d.0}\n' "$i" "$((i + 5))" >> "$B"
done
rc=0; SEED=42 bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a "$A" --arm-b "$B" --n-resamples 2000 --seed 42 > "$OUT_TMP" 2>&1 || rc=$?
assert 'shift rc=0' "[ $rc -eq 0 ]"
assert 'shift .clean.wilcoxon p < 0.05' "jq -e '.clean.wilcoxon.p_value < 0.05' '$OUT_TMP' >/dev/null"
assert 'shift .clean.ci excludes 0 (ci_upper < 0)' "jq -e '.clean.ci.ci_upper < 0' '$OUT_TMP' >/dev/null"
rm -f "$A" "$B"

# Step 7: Missing-key reporting - migrated to .clean.* paths (F2)
A=$(mktemp); B=$(mktemp)
for i in 1 2 3 4 5; do
  printf '{"slug":"s%d","value":%d.0}\n' "$i" "$i" >> "$A"
  printf '{"slug":"s%d","value":%d.0}\n' "$i" "$i" >> "$B"
done
printf '{"slug":"s99","value":99.0}\n' >> "$A"
printf '{"slug":"s88","value":88.0}\n' >> "$B"
rc=0; SEED=42 bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a "$A" --arm-b "$B" --n-resamples 500 --seed 42 > "$OUT_TMP" 2>&1 || rc=$?
assert 'missing-key rc=0' "[ $rc -eq 0 ]"
assert 'missing-key .clean.n_paired=5' "jq -e '.clean.n_paired == 5' '$OUT_TMP' >/dev/null"
assert 'missing_from_b contains s99' "jq -e '.clean.missing_from_b | contains([\"s99\"])' '$OUT_TMP' >/dev/null"
assert 'missing_from_a contains s88' "jq -e '.clean.missing_from_a | contains([\"s88\"])' '$OUT_TMP' >/dev/null"
rm -f "$A" "$B"

# --- F2/F3: subset-aware paired-compare ---
mkdir -p /tmp/tcompare

# Create proper transcript fixtures matching transcript::compact_events detection format.
# clean = 2 assistant turns, no compact boundary.
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > /tmp/tcompare/clean.jsonl
# fired = assistant turn, then compact_boundary system event, then assistant turn.
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":10000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200}}}' \
  > /tmp/tcompare/fired.jsonl

cat > /tmp/tcompare/arm_a.jsonl <<'EOF'
{"slug":"s1","transcript_path":"/tmp/tcompare/clean.jsonl","value":1.0}
{"slug":"s2","transcript_path":"/tmp/tcompare/fired.jsonl","value":2.0}
EOF
cat > /tmp/tcompare/arm_b.jsonl <<'EOF'
{"slug":"s1","transcript_path":"/tmp/tcompare/clean.jsonl","value":1.1}
{"slug":"s2","transcript_path":"/tmp/tcompare/fired.jsonl","value":2.5}
EOF

# F2: --subset clean filters to only clean rows (n_paired=1).
out=$(bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a /tmp/tcompare/arm_a.jsonl --arm-b /tmp/tcompare/arm_b.jsonl --subset clean --json --seed 42 2>&1)
rc=$?
assert 'clean-filter rc=0' "[ $rc -eq 0 ]"
assert 'clean-filter .clean.n_paired=1' "jq -e '.clean.n_paired == 1' <<<\"\$out\" >/dev/null"

# F3: --subset fired emits per-arm gamma bands, no mean_diff/ci, carries caveat.
out=$(bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a /tmp/tcompare/arm_a.jsonl --arm-b /tmp/tcompare/arm_b.jsonl --subset fired --json --seed 42 2>&1)
rc=$?
assert 'fired-subset rc=0' "[ $rc -eq 0 ]"
assert 'F3 arm_a has cost_lower' "jq -e '.fired.gamma_bounded.arm_a.cost_lower != null' <<<\"\$out\" >/dev/null"
assert 'F3 arm_a has cost_upper' "jq -e '.fired.gamma_bounded.arm_a.cost_upper != null' <<<\"\$out\" >/dev/null"
assert 'F3 arm_b has cost_lower' "jq -e '.fired.gamma_bounded.arm_b.cost_lower != null' <<<\"\$out\" >/dev/null"
assert 'F3 arm_b has cost_upper' "jq -e '.fired.gamma_bounded.arm_b.cost_upper != null' <<<\"\$out\" >/dev/null"
assert 'F3 arm_a band_at_1_5 present' "jq -e '.fired.gamma_bounded.arm_a.band_at_1_5' <<<\"\$out\" >/dev/null"
assert 'F3 arm_a band_at_3_0 present' "jq -e '.fired.gamma_bounded.arm_a.band_at_3_0' <<<\"\$out\" >/dev/null"
assert 'F3 fired must not emit mean_diff or point CI' "jq -e '.fired.mean_diff == null and .fired.ci == null' <<<\"\$out\" >/dev/null"
assert 'F3 caveat contains do not point-estimate' "jq -e '.fired.caveat | test(\"do not point-estimate\"; \"i\")' <<<\"\$out\" >/dev/null"

# F2: --subset both emits clean + fired sections.
out=$(bash "$REPO_ROOT/tools/paired-compare.sh" --arm-a /tmp/tcompare/arm_a.jsonl --arm-b /tmp/tcompare/arm_b.jsonl --subset both --json --seed 42 2>&1)
rc=$?
assert 'both-subset rc=0' "[ $rc -eq 0 ]"
assert 'both has .clean' "jq -e '.clean != null' <<<\"\$out\" >/dev/null"
assert 'both has .fired' "jq -e '.fired != null' <<<\"\$out\" >/dev/null"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
