#!/bin/bash
# Tests for context-checkpoint.sh template-aware directive emission.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/context-checkpoint.sh"
FAIL=0

# Test 1: directive output references the active template path, not docs/context-baton.md
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates" "$TMP/.baton/workstreams" "$TMP/.config/baton"
cp "$SCRIPT_DIR/../../share/templates/free.md" "$TMP/share/templates/free.md" 2>/dev/null || echo '# stub free template' > "$TMP/share/templates/free.md"
echo '{"template": "free"}' > "$TMP/.config/baton/config.json"
echo 1 > /tmp/claude-context-pct-test-tpl
echo 28 > /tmp/claude-context-pct-test-tpl
echo 28 > /tmp/claude-context-pct-test-tpl-1

# Simulate PreToolUse input at 28%
input=$(jq -n '{session_id:"test-tpl-1", cwd:"'"$TMP"'", tool_name:"Edit"}')
rm -f /tmp/claude-context-triggered-test-tpl-1
CLAUDE_PROJECT_DIR="$TMP" XDG_CONFIG_HOME="$TMP/.config" out=$(echo "$input" | bash "$HOOK" 2>/dev/null)

echo "$out" | grep -q 'share/templates/free.md' || { echo "FAIL t1: directive should reference resolved template path: $out"; FAIL=1; }
rm -rf "$TMP" /tmp/claude-context-pct-test-tpl* /tmp/claude-context-triggered-test-tpl-1 /tmp/baton-pending-test-tpl-1

# Test 2: BATON_TEMPLATE_PATH env var overrides config
TMP=$(mktemp -d)
mkdir -p "$TMP/.config/baton" "$TMP/custom-templates"
echo '# custom template' > "$TMP/custom-templates/myproject.md"
echo '{"template": "free"}' > "$TMP/.config/baton/config.json"
echo 28 > /tmp/claude-context-pct-test-tpl-2
input=$(jq -n '{session_id:"test-tpl-2", cwd:"'"$TMP"'", tool_name:"Edit"}')
# export vars explicitly so they reach the bash subshell inside $()
export CLAUDE_PROJECT_DIR="$TMP" XDG_CONFIG_HOME="$TMP/.config" BATON_TEMPLATE_PATH="$TMP/custom-templates/myproject.md"
out=$(echo "$input" | bash "$HOOK" 2>/dev/null)
unset CLAUDE_PROJECT_DIR XDG_CONFIG_HOME BATON_TEMPLATE_PATH
echo "$out" | grep -q 'custom-templates/myproject.md' || { echo "FAIL t2: env override not honored: $out"; FAIL=1; }
rm -rf "$TMP" /tmp/claude-context-pct-test-tpl-2 /tmp/claude-context-triggered-test-tpl-2 /tmp/baton-pending-test-tpl-2

# Test 3: missing config falls back to free template at shipped path
TMP=$(mktemp -d)
mkdir -p "$TMP/share/templates"
echo '# shipped free' > "$TMP/share/templates/free.md"
echo 28 > /tmp/claude-context-pct-test-tpl-3
input=$(jq -n '{session_id:"test-tpl-3", cwd:"'"$TMP"'", tool_name:"Edit"}')
CLAUDE_PROJECT_DIR="$TMP" XDG_CONFIG_HOME="$TMP/.config" out=$(echo "$input" | bash "$HOOK" 2>/dev/null)
echo "$out" | grep -q 'share/templates/free.md' || { echo "FAIL t3: missing config should fall back to free template at shipped path: $out"; FAIL=1; }
rm -rf "$TMP" /tmp/claude-context-pct-test-tpl-3 /tmp/claude-context-triggered-test-tpl-3 /tmp/baton-pending-test-tpl-3

if [ "$FAIL" = "0" ]; then echo "PASS test-context-checkpoint-template.sh"; else exit 1; fi
