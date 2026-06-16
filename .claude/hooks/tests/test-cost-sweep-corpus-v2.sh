#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

# Build a 2-transcript fixture corpus: one clean, one compaction-fired.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/proj/ws"

CLEAN="$FIX/proj/ws/clean.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$CLEAN"

FIRED="$FIX/proj/ws/fired.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":15000}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":3000,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  > "$FIRED"

OUT_F="$FIX/out.json"
bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus "$FIX/proj" --json 2>/dev/null > "$OUT_F"

# === v1 backward-compat: existing fields still present ===
assert "schema_version field present" "[ \"\$(jq -r '.schema_version' \"$OUT_F\")\" != 'null' ]"
assert "schema_version is 3" "[ \"\$(jq -r '.schema_version' \"$OUT_F\")\" = '3' ]"
assert "method field present (v1 contract)" "[ \"\$(jq -r '.method' \"$OUT_F\")\" = 'baton-threshold' ]"
assert "transcripts array present (v1 contract)" "[ \"\$(jq -r '.transcripts | length' \"$OUT_F\")\" = '2' ]"
assert "aggregates map present (v1 contract)" "[ \"\$(jq -r '.aggregates | type' \"$OUT_F\")\" = 'object' ]"
assert "typical_best block present (v1 contract)" "[ \"\$(jq -r '.typical_best | type' \"$OUT_F\")\" = 'object' ]"
assert "disclaimer present (v1 contract)" "jq -e '.disclaimer | length > 0' \"$OUT_F\" >/dev/null"

# === v2 new fields present ===
assert "per_arm_per_subset array present" "[ \"\$(jq -r '.per_arm_per_subset | type' \"$OUT_F\")\" = 'array' ]"
assert "per_arm_per_subset has 8 entries (4 arms x 2 subsets)" "[ \"\$(jq -r '.per_arm_per_subset | length' \"$OUT_F\")\" = '8' ]"
assert "per_arm_per_subset contains compact/clean entry" \
  "[ \"\$(jq -r '[.per_arm_per_subset[] | select(.arm==\"compact\" and .subset==\"clean\")] | length' \"$OUT_F\")\" = '1' ]"
assert "per_arm_per_subset contains none/fired entry" \
  "[ \"\$(jq -r '[.per_arm_per_subset[] | select(.arm==\"none\" and .subset==\"fired\")] | length' \"$OUT_F\")\" = '1' ]"
assert "cc12_caveat present and is a string" "[ \"\$(jq -r '.cc12_caveat | type' \"$OUT_F\")\" = 'string' ]"
assert "cc12_caveat mentions marginal-sensitivity-model" \
  "jq -e '.cc12_caveat | contains(\"marginal-sensitivity-model\")' \"$OUT_F\" >/dev/null"
# subset_size_warning: with 1 clean + 1 fired = 50% clean, so warning should be null.
assert "subset_size_warning is null when clean_share >= 30%" \
  "[ \"\$(jq -r '.subset_size_warning' \"$OUT_F\")\" = 'null' ]"

# === Per-arm-per-subset session counts match the fixture (1 clean, 1 fired) ===
for arm in compact auto-memory clear-only none; do
  for subset in clean fired; do
    cnt="$(jq -r --arg a "$arm" --arg s "$subset" \
      '[.per_arm_per_subset[] | select(.arm==$a and .subset==$s)][0].session_count' "$OUT_F")"
    assert "$arm/$subset session_count = 1" "[ \"$cnt\" = '1' ]"
  done
done

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
