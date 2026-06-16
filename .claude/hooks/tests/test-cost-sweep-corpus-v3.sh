#!/usr/bin/env bash
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
assert() {
  local n="$1" c="$2"
  if eval "$c"; then PASS=$((PASS+1)); echo "  PASS  $n"
  else FAIL=$((FAIL+1)); FAILED+=("$n"); echo "  FAIL  $n"; fi
}

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
export BATON_PROGRESS_DIR="$FIXTURE/no-prog" BATON_ARCHIVE_DIR="$FIXTURE/no-arch"

mkdir -p "$FIXTURE/projects/p1" "$FIXTURE/.baton"
cat > "$FIXTURE/projects/p1/session-a.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":25000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF

cat > "$FIXTURE/.baton/audit-metadata.json" <<'EOF'
{"audit_date":"2026-05-24T00:00:00Z","cost_model_version":"1.0.0","stage1_residual_per_arm":{"none":0.034,"auto-memory":0.041,"clear-only":0.022,"compact":0.018},"stage2_residual_per_arm":{"none":0.012,"auto-memory":0.024,"clear-only":0.008,"compact":0.015},"cache_break_detected":false,"next_quarterly_audit_due":"2026-08-24T00:00:00Z"}
EOF

# Point audit_metadata::read at our fixture's .baton dir
export BATON_AUDIT_METADATA="$FIXTURE/.baton/audit-metadata.json"

out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus "$FIXTURE/projects" --json 2>&1)

assert 'json parses' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'schema_version == 3' "printf '%s' \"\$out\" | jq -e '.schema_version == 3' >/dev/null"
assert 'audit_metadata.audit_date present' "printf '%s' \"\$out\" | jq -e '.audit_metadata.audit_date == \"2026-05-24T00:00:00Z\"' >/dev/null"
assert 'audit_metadata.stage1_residual_per_arm.none == 0.034' "printf '%s' \"\$out\" | jq -e '.audit_metadata.stage1_residual_per_arm.none == 0.034' >/dev/null"
assert 'audit_metadata.cache_break_detected == false' "printf '%s' \"\$out\" | jq -e '.audit_metadata.cache_break_detected == false' >/dev/null"
assert 'v2 fields preserved (transcripts present)' "printf '%s' \"\$out\" | jq -e '.transcripts | type == \"array\"' >/dev/null"
assert 'warn_count present and == 0 on happy path' "printf '%s' \"\$out\" | jq -e '.warn_count == 0' >/dev/null"

# === gamma_bands: fired subset ===
mkdir -p "$FIXTURE/projects/p2"
cat > "$FIXTURE/projects/p2/session-b.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":35000}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":15000,"output_tokens":1200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF

out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus "$FIXTURE/projects" --json 2>&1)

PAPS=$(printf '%s' "$out" | jq -c '.per_arm_per_subset // []')
fired_none_cost=$(printf '%s' "$PAPS" | jq -r '.[] | select(.arm == "none" and .subset == "fired") | .usd_total // "0"')
assert 'fixture produces non-zero fired-subset cost for none arm' "awk -v v=\"\$fired_none_cost\" 'BEGIN{exit !(v+0 > 0)}'"
assert 'gamma_bands present for fired subset' "printf '%s' \"\$out\" | jq -e '.gamma_bands != null' >/dev/null"
assert 'gamma_bands.fired.none.gamma_low == 1.5' "printf '%s' \"\$out\" | jq -e '.gamma_bands.fired.none.gamma_low == 1.5' >/dev/null"
assert 'gamma_bands.fired.none.gamma_high == 3.0' "printf '%s' \"\$out\" | jq -e '.gamma_bands.fired.none.gamma_high == 3.0' >/dev/null"
assert 'gamma_bands.fired."auto-memory" present' "printf '%s' \"\$out\" | jq -e '.gamma_bands.fired.\"auto-memory\" != null' >/dev/null"
assert 'gamma_bands.clean is null' "printf '%s' \"\$out\" | jq -e '.gamma_bands.clean == null' >/dev/null"

echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
