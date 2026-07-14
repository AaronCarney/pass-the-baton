#!/bin/bash
# E-D2 Task 1: plugin packaging manifests.
# Asserts .claude-plugin/plugin.json + marketplace.json exist with the structure
# the Claude Code plugin/marketplace loaders require: a SemVer-versioned plugin.json
# (SemVer adopted as of 0.3.0) pointing hooks at ./hooks/hooks.json and skills at the
# existing ./.claude/skills/ dir, and a single-plugin marketplace.json with a
# relative self-source ("./") for local install testing.
#
# Usage: bash .claude/hooks/tests/test-plugin-manifests.sh

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"

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

echo "## plugin packaging manifests"

# ---- plugin.json ----
assert "plugin.json is valid JSON" \
  "jq -e . '$PLUGIN' >/dev/null 2>&1"
assert "plugin.json name == pass-the-baton" \
  "[ \"\$(jq -r .name '$PLUGIN')\" = pass-the-baton ]"
assert "plugin.json has a non-empty description" \
  "[ -n \"\$(jq -r '.description // empty' '$PLUGIN')\" ]"
assert "plugin.json has a SemVer version (adopted as of 0.3.0)" \
  "[[ \"\$(jq -r '.version // empty' '$PLUGIN')\" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]"
assert "plugin.json hooks -> ./hooks/hooks.json" \
  "[ \"\$(jq -r '.hooks' '$PLUGIN')\" = './hooks/hooks.json' ]"
assert "plugin.json skills -> ./.claude/skills/" \
  "[ \"\$(jq -r '.skills' '$PLUGIN')\" = './.claude/skills/' ]"

# ---- marketplace.json ----
assert "marketplace.json is valid JSON" \
  "jq -e . '$MARKET' >/dev/null 2>&1"
assert "marketplace.json has owner.name" \
  "[ -n \"\$(jq -r '.owner.name // empty' '$MARKET')\" ]"
assert "marketplace.json has exactly one plugin entry" \
  "[ \"\$(jq -r '.plugins | length' '$MARKET')\" = 1 ]"
assert "marketplace.json plugins[0].name == pass-the-baton" \
  "[ \"\$(jq -r '.plugins[0].name' '$MARKET')\" = pass-the-baton ]"
assert "marketplace.json plugins[0].source == ./ (relative self-source)" \
  "[ \"\$(jq -r '.plugins[0].source' '$MARKET')\" = './' ]"

# ---- shipped skills carry frontmatter name: ----
for s in baton install-baton; do
  assert "skill $s has frontmatter name:" \
    "grep -qE '^name: *[a-z-]+' '$ROOT/.claude/skills/$s/SKILL.md'"
done

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
