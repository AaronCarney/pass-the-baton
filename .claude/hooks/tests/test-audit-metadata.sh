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

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/audit-metadata.sh"

# === Cycle 1: audit_metadata::read returns {} when file missing ===
FIXTURE=$(mktemp -d)
BATON_AUDIT_METADATA="$FIXTURE/.baton/audit-metadata.json"
export BATON_AUDIT_METADATA
out=$(audit_metadata::read 2>&1)
rc=$?
assert 'read missing file → rc=0' "[ $rc -eq 0 ]"
assert 'read missing file → empty object' "printf '%s' \"$out\" | jq -e '. == {}' >/dev/null"

# === Cycle 2: audit_metadata::stamp_stage1 merges per-arm residuals ===
mkdir -p "$FIXTURE/.baton"
cat > "$FIXTURE/.baton/audit-metadata.json" <<'EOF'
{"audit_date":"2026-05-24T00:00:00Z","cost_model_version":"1.0.0","stage1_residual_per_arm":{"none":null,"auto-memory":null,"clear-only":null,"compact":null},"stage2_residual_per_arm":{"none":null,"auto-memory":null,"clear-only":null,"compact":null}}
EOF
RESIDUAL_JSON='{"none":0.034,"auto-memory":0.041,"clear-only":0.022,"compact":0.018}'
audit_metadata::stamp_stage1 "$RESIDUAL_JSON"
assert 'stage1.none stamped' "jq -e '.stage1_residual_per_arm.none == 0.034' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"
assert 'stage1.auto-memory stamped' "jq -e '.stage1_residual_per_arm[\"auto-memory\"] == 0.041' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"
assert 'stage2 not touched' "jq -e '.stage2_residual_per_arm.none == null' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"

# stamp_stage2 test
RESIDUAL2_JSON='{"none":0.011,"auto-memory":0.015,"clear-only":0.009,"compact":0.007}'
audit_metadata::stamp_stage2 "$RESIDUAL2_JSON" 'false'
assert 'stage2.none stamped' "jq -e '.stage2_residual_per_arm.none == 0.011' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"
assert 'cache_break_detected false' "jq -e '.cache_break_detected == false' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"
assert 'stage1 preserved after stage2' "jq -e '.stage1_residual_per_arm.none == 0.034' \"$FIXTURE/.baton/audit-metadata.json\" >/dev/null"

# === Cycle 3: audit_metadata::is_stale 90-day threshold ===
FIXTURE2=$(mktemp -d)
BATON_AUDIT_METADATA="$FIXTURE2/.baton/audit-metadata.json"
export BATON_AUDIT_METADATA
mkdir -p "$FIXTURE2/.baton"
printf '{"audit_date":"%s"}\n' "$(date -u +%Y-%m-%dT00:00:00Z)" > "$FIXTURE2/.baton/audit-metadata.json"
rc=0; audit_metadata::is_stale || rc=$?
assert 'recent audit → rc=1 (not stale)' "[ $rc -eq 1 ]"

OLD=$(date -u -d '91 days ago' +%Y-%m-%dT00:00:00Z)
printf '{"audit_date":"%s"}\n' "$OLD" > "$FIXTURE2/.baton/audit-metadata.json"
rc=0; audit_metadata::is_stale || rc=$?
assert 'old audit → rc=0 (stale)' "[ $rc -eq 0 ]"

# === Cycle 4: staleness cutoff is a named constant ===
_c=$( source "$REPO_ROOT/lib/audit-metadata.sh"; printf '%s' "$_AUDIT_STALE_DAYS" )
assert "audit-stale-days-90" "[ '$_c' = '90' ]"

# Cleanup
rm -rf "$FIXTURE" "$FIXTURE2"
unset BATON_AUDIT_METADATA

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
