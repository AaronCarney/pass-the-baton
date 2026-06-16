#!/usr/bin/env bash
# .claude/hooks/tests/test-rigor-flag.sh - functional tests for --rigor flag
# Tests: --help presence, workshop CI (via cost-sweep which actually implements it),
# backward-compat default schema (no .ci, no .strata, no .paired_compare, no .hierarchical).
# Note: time-to-complete-corpus.sh --rigor workshop CI attachment requires .wall_clock_seconds
# in sidecar values (T8 wires per-session sidecars); the flag is accepted and validated.
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

# --- Step 1: --help flag-presence assertions for both tools ---

rc=0; out=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --help 2>&1) || rc=$?
assert 'cost-sweep --help exits 0' "[ \"$rc\" -eq 0 ]"
assert 'cost-sweep --help mentions --rigor' "printf '%s' \"\$out\" | grep -q -- '--rigor'"
assert 'cost-sweep --help mentions preprint' "printf '%s' \"\$out\" | grep -q 'preprint'"
assert 'cost-sweep --help mentions workshop' "printf '%s' \"\$out\" | grep -q 'workshop'"
assert 'cost-sweep --help mentions mlsys' "printf '%s' \"\$out\" | grep -q 'mlsys'"

rc=0; out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --help 2>&1) || rc=$?
assert 'time-to-complete --help exits 0' "[ \"$rc\" -eq 0 ]"
assert 'time-to-complete --help mentions --rigor' "printf '%s' \"\$out\" | grep -q -- '--rigor'"
assert 'time-to-complete --help mentions preprint' "printf '%s' \"\$out\" | grep -q 'preprint'"
assert 'time-to-complete --help mentions workshop' "printf '%s' \"\$out\" | grep -q 'workshop'"
assert 'time-to-complete --help mentions mlsys' "printf '%s' \"\$out\" | grep -q 'mlsys'"

# --- Step 2: --rigor validation (invalid value exits non-zero) ---

rc=0; bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" --corpus /tmp --rigor bad 2>/dev/null || rc=$?
assert 'cost-sweep --rigor bad exits non-zero' "[ \"$rc\" -ne 0 ]"

# --- Step 3: Build corpus with varied costs for --rigor workshop CI test ---
# BCA requires non-degenerate input (varied values); 6 sessions per workspace ensures this.

CORPUS="$TMPDIR_ROOT/corpus"
mkdir -p "$CORPUS/wsa" "$CORPUS/wsb"

# wsa: 4 sessions with different (increasing) token counts
for i in 1 2 3 4; do
  printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":%d}}}\n{"type":"user","message":{"role":"user","content":"x"}}\n' \
    $((i*300)) $((i*50)) $((i*800)) > "$CORPUS/wsa/s${i}.jsonl"
done

# wsb: 4 sessions with different (decreasing from large) token counts
for i in 5 6 7 8; do
  printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":%d}}}\n{"type":"user","message":{"role":"user","content":"x"}}\n' \
    $((i*300)) $((i*50)) $((i*800)) > "$CORPUS/wsb/s${i}.jsonl"
done

# --- Step 4: --rigor workshop emits CI blocks in strata ---
# cost-sweep auto-enables --stratify-by workspace when --rigor != preprint;
# CI is attached per-arm under .strata[ws].per_method[arm].ci with method=studentized+log (E15 default).

workshop_out=$(SEED=42 bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" \
  --corpus "$CORPUS" --rigor workshop --json 2>/dev/null)
rc=$?
assert 'cost-sweep --rigor workshop rc=0' "[ \"$rc\" -eq 0 ]"
assert 'cost-sweep --rigor workshop output is valid JSON' \
  "printf '%s' \"\$workshop_out\" | jq -e . >/dev/null"
assert 'cost-sweep --rigor workshop has .strata (auto-enabled)' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata | type == \"object\"' >/dev/null"
assert 'cost-sweep --rigor workshop strata[wsa].per_method.none.ci present' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata.wsa.per_method.none.ci | . != null' >/dev/null"
assert 'cost-sweep --rigor workshop ci.method == studentized+log (E15 default)' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata.wsa.per_method.none.ci.method == \"studentized+log\"' >/dev/null"
assert 'cost-sweep --rigor workshop ci has ci_lower' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata.wsa.per_method.none.ci | has(\"ci_lower\")' >/dev/null"
assert 'cost-sweep --rigor workshop ci has ci_upper' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata.wsa.per_method.none.ci | has(\"ci_upper\")' >/dev/null"
assert 'cost-sweep --rigor workshop ci has n_resamples' \
  "printf '%s' \"\$workshop_out\" | jq -e '.strata.wsa.per_method.none.ci.n_resamples | type == \"number\"' >/dev/null"
assert 'cost-sweep --rigor workshop schema_version unchanged (3)' \
  "printf '%s' \"\$workshop_out\" | jq -e '.schema_version == 3' >/dev/null"

# --- Step 5: time-to-complete --rigor workshop accepted (flag validated, rc=0) ---

EVENTS="$TMPDIR_ROOT/events.jsonl"
cat > "$EVENTS" <<'EOF'
{"ts":"2026-05-01T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-02T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-b","kind":"start","workstream":"main-2","terminal_id":"t2","description":""}}
{"ts":"2026-05-02T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-b","kind":"end","workstream":"main-2","terminal_id":"t2","status":"shipped","note":""}}
{"ts":"2026-05-03T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-c","kind":"start","workstream":"main-3","terminal_id":"t3","description":""}}
{"ts":"2026-05-03T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-c","kind":"end","workstream":"main-3","terminal_id":"t3","status":"shipped","note":""}}
{"ts":"2026-05-04T09:00:00Z","kind":"project_boundary","payload":{"slug":"proj-d","kind":"start","workstream":"main-4","terminal_id":"t4","description":""}}
{"ts":"2026-05-04T10:30:00Z","kind":"project_boundary","payload":{"slug":"proj-d","kind":"end","workstream":"main-4","terminal_id":"t4","status":"shipped","note":""}}
EOF

ttc_workshop_out=$(SEED=42 bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS" --corpus "$CORPUS" --rigor workshop --json 2>/dev/null)
rc=$?
assert 'time-to-complete --rigor workshop rc=0' "[ \"$rc\" -eq 0 ]"
assert 'time-to-complete --rigor workshop output is valid JSON' \
  "printf '%s' \"\$ttc_workshop_out\" | jq -e . >/dev/null"
assert 'time-to-complete --rigor workshop schema_version == 1' \
  "printf '%s' \"\$ttc_workshop_out\" | jq -e '.schema_version == 1' >/dev/null"
assert 'time-to-complete --rigor workshop has per_method' \
  "printf '%s' \"\$ttc_workshop_out\" | jq -e '.per_method | type == \"object\"' >/dev/null"

# --- Step 6: Backward-compat assertion (default invocation) ---
# Default invocation (no --rigor, no --stratify-by) must produce schema identical
# to pre-E15 baseline: no .strata, no .ci in per_method, no .paired_compare, no .hierarchical.

default_cs=$(bash "$REPO_ROOT/tools/cost-sweep-corpus.sh" \
  --corpus "$CORPUS" --json 2>/dev/null)
assert 'default cost-sweep: valid JSON' \
  "printf '%s' \"\$default_cs\" | jq -e . >/dev/null"
assert 'default cost-sweep: schema_version == 3' \
  "printf '%s' \"\$default_cs\" | jq -e '.schema_version == 3' >/dev/null"
assert 'default cost-sweep: no .strata' \
  "printf '%s' \"\$default_cs\" | jq -e '.strata // null | . == null' >/dev/null"
assert 'default cost-sweep: no .paired_compare' \
  "printf '%s' \"\$default_cs\" | jq -e '.paired_compare // null | . == null' >/dev/null"
assert 'default cost-sweep: no .hierarchical' \
  "printf '%s' \"\$default_cs\" | jq -e '.hierarchical // null | . == null' >/dev/null"

default_ttc=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS" --corpus "$CORPUS" --json 2>/dev/null)
assert 'default time-to-complete: valid JSON' \
  "printf '%s' \"\$default_ttc\" | jq -e . >/dev/null"
assert 'default time-to-complete: schema_version == 1' \
  "printf '%s' \"\$default_ttc\" | jq -e '.schema_version == 1' >/dev/null"
assert 'default time-to-complete: no .strata' \
  "printf '%s' \"\$default_ttc\" | jq -e '.strata // null | . == null' >/dev/null"
assert 'default time-to-complete: per_method has no .ci' \
  "printf '%s' \"\$default_ttc\" | jq -e '[.per_method[] | .ci // null] | all(. == null)' >/dev/null"
assert 'default time-to-complete: no .paired_compare' \
  "printf '%s' \"\$default_ttc\" | jq -e '.paired_compare // null | . == null' >/dev/null"
assert 'default time-to-complete: no .hierarchical' \
  "printf '%s' \"\$default_ttc\" | jq -e '.hierarchical // null | . == null' >/dev/null"

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
