#!/usr/bin/env bash
# test-export.sh - tests for tools/export.sh (OTel export subcommand, E-D Task 1).
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
EXPORT="$REPO_ROOT/tools/export.sh"

PASS=0; FAIL=0; FAILED_CASES=()
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); echo "  PASS  $name"
  else FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config"
LOG="$TMP/state/baton/hook-events.jsonl"
mkdir -p "$TMP/state/baton"
export BATON_EVENT_LOG="$LOG"

KNOWN='{"schema":"baton.event.v1","event":"cost_rollup","ts":"2026-06-21T00:00:00Z","data":{"model":"claude-opus-4-8","custom_field":"keep_me"}}'

echo "## syntax"
assert "export.sh parses" "bash -n '$EXPORT'"

echo "## gate OFF"
unset BATON_OTEL_EXPORT
printf '%s\n' "$KNOWN" > "$LOG"
errf="$TMP/err"
out=$(bash "$EXPORT" --otel 2>"$errf"); rc=$?
err=$(cat "$errf")
assert "gate OFF -> nonzero exit" "[ \"$rc\" -ne 0 ]"
assert "gate OFF -> no stdout" "[ -z \"$out\" ]"
assert "gate OFF -> stderr names BATON_OTEL_EXPORT" "printf '%s' \"\$err\" | grep -q BATON_OTEL_EXPORT"

echo "## gate ON -- rename"
export BATON_OTEL_EXPORT=1
out=$(bash "$EXPORT" --otel)
assert "gate ON -> gen_ai.request.model present" "printf '%s' \"\$out\" | jq -e '.data[\"gen_ai.request.model\"] == \"claude-opus-4-8\"' >/dev/null"
assert "gate ON -> original data.model gone" "[ \"\$(printf '%s' \"\$out\" | jq -r '.data.model')\" = 'null' ]"
assert "gate ON -> envelope event preserved" "[ \"\$(printf '%s' \"\$out\" | jq -r '.event')\" = 'cost_rollup' ]"
assert "gate ON -> envelope ts preserved" "[ \"\$(printf '%s' \"\$out\" | jq -r '.ts')\" = '2026-06-21T00:00:00Z' ]"
assert "gate ON -> unmapped key passes through" "[ \"\$(printf '%s' \"\$out\" | jq -r '.data.custom_field')\" = 'keep_me' ]"

echo "## gate ON -- missing log"
rm -f "$LOG"
out=$(bash "$EXPORT" --otel); rc=$?
assert "missing log -> exit 0" "[ \"$rc\" -eq 0 ]"
assert "missing log -> empty stdout" "[ -z \"$out\" ]"

echo "## gate ON -- multi-event line count preserved"
printf '%s\n%s\n%s\n' "$KNOWN" "$KNOWN" "$KNOWN" > "$LOG"
n=$(bash "$EXPORT" --otel | wc -l | tr -d ' ')
assert "3 input lines -> 3 output lines" "[ \"$n\" -eq 3 ]"

echo "## gate ON -- torn line in the middle is dropped, good lines survive"
# A corrupt/zero-filled middle line must NOT abort the export (CC20 tolerant read).
{ printf '%s\n' "$KNOWN"; printf 'not json{{\n'; printf '%s\n' "$KNOWN"; } > "$LOG"
out=$(bash "$EXPORT" --otel); rc=$?
assert "torn middle line -> exit 0" "[ \"$rc\" -eq 0 ]"
assert "torn middle line -> 2 good lines still emitted" "[ \"\$(printf '%s' \"\$out\" | grep -c 'gen_ai.request.model')\" -eq 2 ]"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
