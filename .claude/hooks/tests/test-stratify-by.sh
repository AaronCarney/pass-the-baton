#!/usr/bin/env bash
# .claude/hooks/tests/test-stratify-by.sh - functional tests for --stratify-by flag
# Tests: flag acceptance (--help), strata key presence, per-stratum shape, backward compat.
# Impl source of truth: tools/cost-sweep-corpus.sh (which emits .strata);
# tools/time-to-complete-corpus.sh accepts the flag but does not yet emit .strata (T8 scope).
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PASS=0; FAIL=0

assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL: %s\n' "$label" >&2
  fi
}

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT
export BATON_PROGRESS_DIR="$TMPDIR_ROOT/no-prog"
export BATON_ARCHIVE_DIR="$TMPDIR_ROOT/no-arch"

# --- Step 1: --help flag-presence assertions ---

rc=0; out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --help 2>&1) || rc=$?
assert 'cost-sweep --help exits 0' "[ \"$rc\" -eq 0 ]"
assert 'cost-sweep --help mentions --stratify-by' "printf '%s' \"\$out\" | grep -q -- '--stratify-by'"

rc=0; out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --help 2>&1) || rc=$?
assert 'time-to-complete --help exits 0' "[ \"$rc\" -eq 0 ]"
assert 'time-to-complete --help mentions --stratify-by' "printf '%s' \"\$out\" | grep -q -- '--stratify-by'"

# --- Step 2: Build 2-workspace corpus for cost-sweep --stratify-by workspace ---
# cost-sweep-corpus.sh is the tool that emits .strata (time-to-complete accepts the
# flag without error but does not yet produce .strata in its JSON output).

CORPUS="$TMPDIR_ROOT/corpus"
mkdir -p "$CORPUS/wsa" "$CORPUS/wsb"

# wsa: 3 sessions with varied costs to avoid BCA degenerate-input path
for i in 1 2 3; do
  printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":%d}}}\n{"type":"user","message":{"role":"user","content":"x"}}\n' \
    $((i*300)) $((i*50)) $((i*800)) > "$CORPUS/wsa/s${i}.jsonl"
done

# wsb: 3 sessions with different varied costs
for i in 4 5 6; do
  printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":%d}}}\n{"type":"user","message":{"role":"user","content":"x"}}\n' \
    $((i*300)) $((i*50)) $((i*800)) > "$CORPUS/wsb/s${i}.jsonl"
done

# Run cost-sweep with --stratify-by workspace
stratify_out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" \
  --corpus "$CORPUS" --stratify-by workspace --json 2>/dev/null)
rc=$?

assert 'cost-sweep --stratify-by workspace rc=0' "[ \"$rc\" -eq 0 ]"
assert 'cost-sweep --stratify-by output is valid JSON' \
  "printf '%s' \"\$stratify_out\" | jq -e . >/dev/null"
assert 'cost-sweep --stratify-by output has .strata' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata' >/dev/null"
assert 'cost-sweep --stratify-by .strata has exactly 2 keys' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata | keys | length == 2' >/dev/null"
assert 'cost-sweep --stratify-by .strata has wsa key' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata | has(\"wsa\")' >/dev/null"
assert 'cost-sweep --stratify-by .strata has wsb key' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata | has(\"wsb\")' >/dev/null"
assert 'cost-sweep --stratify-by strata[wsa] has per_method object' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata.wsa.per_method | type == \"object\"' >/dev/null"
assert 'cost-sweep --stratify-by strata[wsb] has per_method object' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata.wsb.per_method | type == \"object\"' >/dev/null"
assert 'cost-sweep --stratify-by strata[wsa].per_method.none.n == 3' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata.wsa.per_method.none.n == 3' >/dev/null"
assert 'cost-sweep --stratify-by strata[wsb].per_method.none.n == 3' \
  "printf '%s' \"\$stratify_out\" | jq -e '.strata.wsb.per_method.none.n == 3' >/dev/null"
# schema_version unchanged (additive sibling key, no bump)
assert 'cost-sweep --stratify-by schema_version still 3' \
  "printf '%s' \"\$stratify_out\" | jq -e '.schema_version == 3' >/dev/null"

# --- Step 3: time-to-complete accepts --stratify-by without error ---

EVENTS="$TMPDIR_ROOT/events.jsonl"
cat > "$EVENTS" <<'EOF'
{"ts":"2026-05-01T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-02T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-b","kind":"start","workstream":"main-2","terminal_id":"t2","description":""}}
{"ts":"2026-05-02T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-b","kind":"end","workstream":"main-2","terminal_id":"t2","status":"shipped","note":""}}
EOF

ttc_out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS" --corpus "$CORPUS" --stratify-by workspace --json 2>/dev/null)
rc=$?
assert 'time-to-complete --stratify-by workspace rc=0' "[ \"$rc\" -eq 0 ]"
assert 'time-to-complete --stratify-by output is valid JSON' \
  "printf '%s' \"\$ttc_out\" | jq -e . >/dev/null"
assert 'time-to-complete --stratify-by schema_version == 1' \
  "printf '%s' \"\$ttc_out\" | jq -e '.schema_version == 1' >/dev/null"

# --- Step 4: Backward-compat assertion ---
# Default invocation (no --stratify-by) must produce no .strata, no E15 extension keys.

default_out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" \
  --corpus "$CORPUS" --json 2>/dev/null)
assert 'default cost-sweep: no .strata' \
  "printf '%s' \"\$default_out\" | jq -e '.strata // null | . == null' >/dev/null"
assert 'default cost-sweep: no .paired_compare' \
  "printf '%s' \"\$default_out\" | jq -e '.paired_compare // null | . == null' >/dev/null"
assert 'default cost-sweep: no .hierarchical' \
  "printf '%s' \"\$default_out\" | jq -e '.hierarchical // null | . == null' >/dev/null"

ttc_default_out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS" --corpus "$CORPUS" --json 2>/dev/null)
assert 'default time-to-complete: no .strata' \
  "printf '%s' \"\$ttc_default_out\" | jq -e '.strata // null | . == null' >/dev/null"
assert 'default time-to-complete: no .paired_compare' \
  "printf '%s' \"\$ttc_default_out\" | jq -e '.paired_compare // null | . == null' >/dev/null"
assert 'default time-to-complete: no .hierarchical' \
  "printf '%s' \"\$ttc_default_out\" | jq -e '.hierarchical // null | . == null' >/dev/null"

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
