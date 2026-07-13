#!/bin/bash
# Shipping SKILL.md files that invoke a bundled tool must resolve it in a way
# that works for a PLUGIN install, where the skill runs from
# ${CLAUDE_PLUGIN_ROOT} while $CLAUDE_PROJECT_DIR points at the user's own
# project (which has no tools/ or .claude/hooks/lib/). A bare
# "$CLAUDE_PROJECT_DIR/tools/<x>.sh" therefore breaks for plugin users.
#
# Guard: no shipping SKILL.md may invoke a tool via bare $CLAUDE_PROJECT_DIR;
# the runtime skills (resume, baton) must route through CLAUDE_PLUGIN_ROOT.
#
# Usage: bash .claude/hooks/tests/test-skill-tool-paths.sh

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILLS_DIR="$ROOT/.claude/skills"

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

assert "skills dir exists" "[ -d '$SKILLS_DIR' ]"

# No shipping SKILL.md may invoke a bundled tool via $CLAUDE_PROJECT_DIR WITHOUT
# a ${CLAUDE_PLUGIN_ROOT} fallback on the same line - that breaks for plugin
# installs. A line carrying both (the `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}`
# fallback) is correct; the install-baton skill's <repo> placeholder (clone
# flow) references neither and is fine.
bad=0
while IFS= read -r skill; do
  # Lines that invoke a bundled tool and lean on CLAUDE_PROJECT_DIR but offer no
  # CLAUDE_PLUGIN_ROOT fallback.
  hits="$(grep -nE '/tools/[A-Za-z0-9._-]+\.sh' "$skill" \
          | grep -F 'CLAUDE_PROJECT_DIR' | grep -vF 'CLAUDE_PLUGIN_ROOT' || true)"
  if [ -n "$hits" ]; then
    bad=1
    echo "    broken plugin path in: ${skill#$ROOT/}"
    echo "$hits" | sed 's/^/      /'
  fi
done < <(find "$SKILLS_DIR" -name SKILL.md)
assert "no SKILL.md invokes a tool via \$CLAUDE_PROJECT_DIR with no \${CLAUDE_PLUGIN_ROOT} fallback" '[ "$bad" = 0 ]'

# The runtime skills that drive a bundled CLI must route through
# ${CLAUDE_PLUGIN_ROOT} so they resolve inside the plugin cache.
for s in baton; do
  f="$SKILLS_DIR/$s/SKILL.md"
  assert "$s skill exists" "[ -f '$f' ]"
  assert "$s skill routes its tool through \${CLAUDE_PLUGIN_ROOT}" \
    "grep -qE 'CLAUDE_PLUGIN_ROOT[^}]*\\}?/tools/' '$f'"
done

# Bundled CLIs in the resume chain run from ${CLAUDE_PLUGIN_ROOT} for a plugin
# install, so they must self-locate their lib + sibling tools via BASH_SOURCE -
# a bare "$PROJECT_DIR/.claude/hooks/lib" or "$PROJECT_DIR/tools" base breaks for
# plugin users (where $PROJECT_DIR is the consumer project, not the plugin root).
TOOLS_DIR="$ROOT/tools"
for t in restore-workstream; do
  f="$TOOLS_DIR/$t.sh"
  assert "$t.sh exists" "[ -f '$f' ]"
  assert "$t.sh self-locates via BASH_SOURCE" \
    "grep -qF 'BASH_SOURCE' '$f'"
  # Any sibling-tool or hooks-lib reference must carry a self-located base
  # (SCRIPT_DIR) somewhere in the file - not rely solely on \$PROJECT_DIR.
  assert "$t.sh resolves hooks-lib relative to SCRIPT_DIR" \
    "grep -qE 'SCRIPT_DIR[^\"]*\\.claude/hooks/lib' '$f'"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
fi
[ "$FAIL" -eq 0 ]
