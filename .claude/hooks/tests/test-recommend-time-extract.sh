#!/usr/bin/env bash
# .claude/hooks/tests/test-recommend-time-extract.sh - TDD for lib/recommend-time-extract.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$REPO_ROOT/lib/recommend-time-extract.sh"

PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$label"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label" >&2
  fi
}

FIXTURE_DIR="$REPO_ROOT/.claude/hooks/tests/fixtures/recommend"
TIME_REAL="$FIXTURE_DIR/time-real.json"
TIME_EMPTY=$(mktemp)
printf '{"per_method":{}}\n' > "$TIME_EMPTY"

# ---- (a) winner returns the method with min median_seconds ----
winner=$(recommend_time::winner "$TIME_REAL")
assert 'winner returns a non-empty method-id' "[ -n \"$winner\" ]"
assert 'winner is compact (min median among compact=5400 none=7200)' "[ \"$winner\" = 'compact' ]"

# ---- (b) per_method returns object with n, mean_seconds, median_seconds, ci preserved ----
pm=$(recommend_time::per_method "$TIME_REAL")
assert 'per_method returns valid JSON object' "printf '%s' \"\$pm\" | jq -e 'type == \"object\"' >/dev/null"
assert 'per_method compact.n present' "printf '%s' \"\$pm\" | jq -e '.compact.n != null' >/dev/null"
assert 'per_method compact.mean_seconds present' "printf '%s' \"\$pm\" | jq -e '.compact.mean_seconds != null' >/dev/null"
assert 'per_method compact.median_seconds present' "printf '%s' \"\$pm\" | jq -e '.compact.median_seconds != null' >/dev/null"
assert 'per_method compact.ci present (CI passthrough)' "printf '%s' \"\$pm\" | jq -e '.compact.ci != null' >/dev/null"
assert 'per_method none.ci present (CI passthrough)' "printf '%s' \"\$pm\" | jq -e '.none.ci != null' >/dev/null"
assert 'per_method ci.ci_lower is numeric' "printf '%s' \"\$pm\" | jq -e '.compact.ci.ci_lower | type == \"number\"' >/dev/null"

# ---- (c) empty per_method → null winner + empty per_method (no crash) ----
empty_winner=$(recommend_time::winner "$TIME_EMPTY")
assert 'empty per_method → winner is null' "[ \"$empty_winner\" = 'null' ]"
empty_pm=$(recommend_time::per_method "$TIME_EMPTY")
assert 'empty per_method → per_method is {}' "printf '%s' \"\$empty_pm\" | jq -e '. == {}' >/dev/null"

# ---- (d) producer-contract: run real tool, assert winner is a string ----
TMPDIR_PC=$(mktemp -d)
cat > "$TMPDIR_PC/events.jsonl" << 'EVENTS'
{"ts":"2026-01-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"pc-a","kind":"start","workstream":"main","terminal_id":"t1","description":""}}
{"ts":"2026-01-01T11:30:00Z","kind":"project_boundary","payload":{"slug":"pc-a","kind":"end","workstream":"main","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-01-02T10:00:00Z","kind":"project_boundary","payload":{"slug":"pc-b","kind":"start","workstream":"main","terminal_id":"t2","description":""}}
{"ts":"2026-01-02T12:00:00Z","kind":"project_boundary","payload":{"slug":"pc-b","kind":"end","workstream":"main","terminal_id":"t2","status":"shipped","note":""}}
{"ts":"2026-01-03T10:00:00Z","kind":"project_boundary","payload":{"slug":"pc-c","kind":"start","workstream":"main","terminal_id":"t3","description":""}}
{"ts":"2026-01-03T11:45:00Z","kind":"project_boundary","payload":{"slug":"pc-c","kind":"end","workstream":"main","terminal_id":"t3","status":"shipped","note":""}}
EVENTS

PC_CORPUS="$TMPDIR_PC/corpus"
mkdir -p "$PC_CORPUS"/-home-context-pc-{a,b,c}
printf '{"ts":"2026-01-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}\n' \
  > "$PC_CORPUS/-home-context-pc-a/sessa.jsonl"
printf '{"ts":"2026-01-02T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}\n' \
  > "$PC_CORPUS/-home-context-pc-b/sessb.jsonl"
printf '{"ts":"2026-01-03T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n' \
  > "$PC_CORPUS/-home-context-pc-c/sessc.jsonl"

PC_OUT=$(mktemp)
bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$TMPDIR_PC/events.jsonl" --corpus "$PC_CORPUS" --rigor workshop --json > "$PC_OUT"
pc_winner=$(recommend_time::winner "$PC_OUT")
assert 'producer-contract winner is non-empty string' "[ -n \"$pc_winner\" ] && [ \"$pc_winner\" != 'null' ]"
printf 'PRODUCER_CONTRACT_TIME_OK\n'
rm -rf "$TMPDIR_PC" "$PC_OUT"

rm -f "$TIME_EMPTY"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
