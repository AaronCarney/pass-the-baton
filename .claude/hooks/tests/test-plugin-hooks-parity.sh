#!/bin/bash
# E-D2 Task 2: hooks/hooks.json must register EXACTLY the 11 canonical hook
# wirings that the installers produce (merge-settings.sh 8 core + install.sh 3
# telemetry), each command routed through ${CLAUDE_PLUGIN_ROOT} and referencing a
# bundled .claude/hooks/<name>.sh file.
#
# The matcher "Write|Edit|MultiEdit" itself contains '|', so triples are compared
# as JSON arrays [event, matcher, script-basename] - never split on a raw '|'.
#
# Usage: bash .claude/hooks/tests/test-plugin-hooks-parity.sh

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS_JSON="$ROOT/hooks/hooks.json"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# Canonical EXPECTED wiring: [event, matcher, script-basename] triples.
# 8 core (merge-settings.sh EVENTS/MATCHERS/COMMANDS) + 3 telemetry (install.sh).
EXPECTED_TRIPLES=(
  '["PostToolBatch","","post-tool-batch.sh"]'
  '["Stop","","stop-relaunch-trigger.sh"]'
  '["PostToolUse","Bash","outcome-proxy-code-execution.sh"]'
  '["PostToolUse","Write|Edit|MultiEdit","checkpoint-write-trigger.sh"]'
  '["PostToolUse","","tool-timing.sh"]'
  '["PreToolUse","","context-checkpoint.sh"]'
  '["SessionEnd","","cleanup-on-exit.sh"]'
  '["SessionStart","","session-start.sh"]'
  '["SubagentStop","","post-subagent-cost.sh"]'
  '["UserPromptSubmit","","outcome-proxy-retry-density.sh"]'
  '["UserPromptSubmit","","project-detect.sh"]'
)

# Gate: file present and valid JSON before any jq extraction.
assert "hooks.json exists" "[ -f '$HOOKS_JSON' ]"
assert "hooks.json is valid JSON" "jq -e . '$HOOKS_JSON' >/dev/null 2>&1"

if [ ! -f "$HOOKS_JSON" ] || ! jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# Build ACTUAL triples from the plugin file. Reduce each command to its script
# basename by stripping the bash "${CLAUDE_PLUGIN_ROOT}/.claude/hooks/ prefix and
# trailing ". Emit one compact JSON array per registration.
EXPECTED_SORTED="$(printf '%s\n' "${EXPECTED_TRIPLES[@]}" | jq -cS . | sort -u)"
ACTUAL_SORTED="$(jq -c '
  .hooks | to_entries[] | .key as $ev | .value[] | (.matcher // "") as $m |
  .hooks[] | [$ev, $m, (.command
    | sub("^bash \"\\$\\{CLAUDE_PLUGIN_ROOT\\}/\\.claude/hooks/"; "")
    | sub("\"$"; ""))]
' "$HOOKS_JSON" | jq -cS . | sort -u)"

assert "ACTUAL triple set EQUALS EXPECTED canonical set (no missing/extra/dup)" \
  '[ "$ACTUAL_SORTED" = "$EXPECTED_SORTED" ]'

if [ "$ACTUAL_SORTED" != "$EXPECTED_SORTED" ]; then
  echo "    --- expected ---"; echo "$EXPECTED_SORTED" | sed 's/^/    /'
  echo "    --- actual ---";   echo "$ACTUAL_SORTED"   | sed 's/^/    /'
fi

# Registration count is exactly 11.
COUNT="$(jq '[.hooks[][] | .hooks[]] | length' "$HOOKS_JSON")"
assert "registration count is exactly 11" '[ "$COUNT" = 11 ]'

# Every command uses ${CLAUDE_PLUGIN_ROOT} and references an existing bundled file.
ALL_CMDS="$(jq -r '.hooks[][] | .hooks[] | .command' "$HOOKS_JSON")"
cmd_fail=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if [[ "$cmd" =~ ^bash\ \"\$\{CLAUDE_PLUGIN_ROOT\}/\.claude/hooks/([A-Za-z0-9._-]+\.sh)\"$ ]]; then
    script="${BASH_REMATCH[1]}"
    [ -f "$ROOT/.claude/hooks/$script" ] || { cmd_fail=1; echo "    missing bundled file: $script"; }
  else
    cmd_fail=1; echo "    command does not use \${CLAUDE_PLUGIN_ROOT} pattern: $cmd"
  fi
done <<< "$ALL_CMDS"
assert "every command uses \${CLAUDE_PLUGIN_ROOT} + references an existing bundled file" \
  '[ "$cmd_fail" = 0 ]'

# No command references $CLAUDE_PROJECT_DIR or $REPO_DIR.
assert "no command references CLAUDE_PROJECT_DIR or REPO_DIR" \
  "! grep -qE 'CLAUDE_PROJECT_DIR|REPO_DIR' '$HOOKS_JSON'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
fi
[ "$FAIL" -eq 0 ]
