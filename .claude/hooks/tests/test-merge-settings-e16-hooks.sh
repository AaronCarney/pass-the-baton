#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MERGE="$REPO_ROOT/tools/merge-settings.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
assert() { local label="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi; }

assert 'merge-settings.sh references outcome-proxy-code-execution' "grep -q 'outcome-proxy-code-execution\.sh' \"$MERGE\""
assert 'merge-settings.sh references outcome-proxy-retry-density' "grep -q 'outcome-proxy-retry-density\.sh' \"$MERGE\""

# Interface check - positional <settings.json> (no --target/--source flags).
assert 'merge-settings.sh CLI is `<settings.json>` positional (no --target flag)' "grep -qE 'TARGET=\\\"\\\$\{1:\?' \"$MERGE\""

# ── E2E case 1: merge into EMPTY settings.json fixture ────────────────────
echo '{"hooks": {}}' > "$TMP/empty-target.json"
set +e
bash "$MERGE" "$TMP/empty-target.json" >"$TMP/empty.log" 2>&1
rc_empty=$?
set -e
assert 'merge into empty target exits 0' "[ $rc_empty -eq 0 ]"
# String-presence assertions (any-key) - broad coverage.
assert 'empty-merge contains outcome-proxy-code-execution' "jq -e '[.. | strings? | select(test(\"outcome-proxy-code-execution.sh\"))] | length > 0' \"$TMP/empty-target.json\""
assert 'empty-merge contains outcome-proxy-retry-density' "jq -e '[.. | strings? | select(test(\"outcome-proxy-retry-density.sh\"))] | length > 0' \"$TMP/empty-target.json\""
# Hook-event-key correctness - locks the protocol contract.
assert 'outcome-proxy-code-execution wired under PostToolUse with Bash matcher' "jq -e '.hooks.PostToolUse[] | select(.matcher == \"Bash\") | .hooks[]? | select(.command | test(\"outcome-proxy-code-execution.sh\"))' \"$TMP/empty-target.json\""
assert 'outcome-proxy-retry-density wired under UserPromptSubmit' "jq -e '.hooks.UserPromptSubmit[]? | .hooks[]? | select(.command | test(\"outcome-proxy-retry-density.sh\"))' \"$TMP/empty-target.json\""
# Pre-existing same-event entries also land (PostToolUse for checkpoint-write-trigger, UserPromptSubmit for project-detect).
assert 'empty-merge also wires checkpoint-write-trigger under PostToolUse with Write|Edit|MultiEdit matcher' "jq -e '.hooks.PostToolUse[] | select(.matcher == \"Write|Edit|MultiEdit\") | .hooks[]? | select(.command | test(\"checkpoint-write-trigger.sh\"))' \"$TMP/empty-target.json\""
assert 'empty-merge also wires project-detect under UserPromptSubmit' "jq -e '.hooks.UserPromptSubmit[]? | .hooks[]? | select(.command | test(\"project-detect.sh\"))' \"$TMP/empty-target.json\""

# ── E2E case 2: merge into target WITH PRE-EXISTING hooks (load-bearing) ──
# Pre-seed checkpoint-write-trigger + project-detect manually, then merge - verify the 2 new outcome-proxy entries land
# AND the 2 pre-existing entries SURVIVE (the multi-entry-per-event refactor must not clobber).
cat > "$TMP/preseeded-target.json" <<'PRESEED'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "bash /custom/path/checkpoint-write-trigger.sh"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bash /custom/path/project-detect.sh"}]}
    ]
  }
}
PRESEED
set +e
bash "$MERGE" "$TMP/preseeded-target.json" >"$TMP/preseeded.log" 2>&1
rc_pre=$?
set -e
assert 'merge into pre-seeded target exits 0' "[ $rc_pre -eq 0 ]"
# Pre-existing entries survive (their distinct command paths still present).
assert 'pre-existing /custom/path/checkpoint-write-trigger.sh survives merge' "jq -e '[.. | strings? | select(test(\"/custom/path/checkpoint-write-trigger.sh\"))] | length > 0' \"$TMP/preseeded-target.json\""
assert 'pre-existing /custom/path/project-detect.sh survives merge' "jq -e '[.. | strings? | select(test(\"/custom/path/project-detect.sh\"))] | length > 0' \"$TMP/preseeded-target.json\""
# New entries also land alongside the pre-existing ones.
assert 'new outcome-proxy-code-execution lands alongside pre-existing PostToolUse hook' "jq -e '.hooks.PostToolUse | length >= 2' \"$TMP/preseeded-target.json\""
assert 'new outcome-proxy-retry-density lands alongside pre-existing UserPromptSubmit hook' "jq -e '.hooks.UserPromptSubmit | length >= 2' \"$TMP/preseeded-target.json\""
assert 'pre-seed merge contains outcome-proxy-code-execution (new)' "jq -e '[.. | strings? | select(test(\"outcome-proxy-code-execution.sh\"))] | length > 0' \"$TMP/preseeded-target.json\""
assert 'pre-seed merge contains outcome-proxy-retry-density (new)' "jq -e '[.. | strings? | select(test(\"outcome-proxy-retry-density.sh\"))] | length > 0' \"$TMP/preseeded-target.json\""

# ── Idempotency: re-merge MUST NOT duplicate any entry ────────────────────
bash "$MERGE" "$TMP/empty-target.json" >/dev/null 2>&1
count_ce=$(jq -r '[.. | strings? | select(test("outcome-proxy-code-execution.sh"))] | length' "$TMP/empty-target.json")
count_rd=$(jq -r '[.. | strings? | select(test("outcome-proxy-retry-density.sh"))] | length' "$TMP/empty-target.json")
assert 'idempotent re-merge does NOT duplicate code-execution hook' "[ \"$count_ce\" = \"1\" ]"
assert 'idempotent re-merge does NOT duplicate retry-density hook' "[ \"$count_rd\" = \"1\" ]"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
