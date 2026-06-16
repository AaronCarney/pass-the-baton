#!/bin/bash
# test-prompt-sync.sh - enforce verbatim parity of the 5 first-time-setup
# prompts across install.sh, install.md, and the install-baton SKILL.md.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"

PASSED=0
FAILED=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASSED=$((PASSED+1)); echo "  PASS  $name"
  else
    FAILED=$((FAILED+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# Extract prompt text from install.sh: P[N]_TEXT='...' multi-line bash strings.
# Uses stateful awk to collect lines between the opening quote and closing quote,
# then strips all whitespace for a normalized comparison string.
prompts_install_sh() {
  awk '/PROMPT-SYNC-BEGIN/{flag=1; next} /PROMPT-SYNC-END/{flag=0} flag' \
    "$REPO_DIR/tools/install.sh" \
  | awk '
    /^P[1-5]_TEXT='"'"'/ {
      in_text=1
      sub(/^P[1-5]_TEXT='"'"'/, "")
      if (/'"'"'$/) { sub(/'"'"'$/, ""); in_text=0 }
      print; next
    }
    in_text {
      if (/'"'"'$/) { sub(/'"'"'$/, ""); in_text=0 }
      print
    }
  ' | tr -d ' \t\n'
}

# Extract prompt text from a markdown file: content inside ``` fenced blocks
# within the PROMPT-SYNC region, whitespace-normalized.
prompts_md_blocks() {
  awk '/PROMPT-SYNC-BEGIN/{flag=1; next} /PROMPT-SYNC-END/{flag=0} flag' "$1" \
    | awk '/^```/{in_fence=!in_fence; next} in_fence' \
    | tr -d ' \t\n'
}

INSTALL_PROMPTS=$(prompts_install_sh)
MD_PROMPTS=$(prompts_md_blocks "$REPO_DIR/docs/install.md")
SKILL_PROMPTS=$(prompts_md_blocks "$REPO_DIR/.claude/skills/install-baton/SKILL.md")

# Guard against vacuous pass: all three empty would make equality hold trivially.
if [ -z "$INSTALL_PROMPTS" ] || [ -z "$MD_PROMPTS" ] || [ -z "$SKILL_PROMPTS" ]; then
  echo "ERROR: one or more PROMPT-SYNC regions extracted empty - check markers."
  echo "  install.sh: ${#INSTALL_PROMPTS} chars"
  echo "  install.md: ${#MD_PROMPTS} chars"
  echo "  SKILL.md:   ${#SKILL_PROMPTS} chars"
  exit 1
fi

assert "PROMPT-SYNC: install.sh and install.md match" \
  "[ \"\$INSTALL_PROMPTS\" = \"\$MD_PROMPTS\" ]"
assert "PROMPT-SYNC: install.sh and SKILL.md match" \
  "[ \"\$INSTALL_PROMPTS\" = \"\$SKILL_PROMPTS\" ]"
assert "PROMPT-SYNC: install.md and SKILL.md match" \
  "[ \"\$MD_PROMPTS\" = \"\$SKILL_PROMPTS\" ]"

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  echo ""
  echo "Diff hints:"
  echo "  diff <(tools/extract-prompts install.sh) <(tools/extract-prompts install.md)"
  echo "  diff <(tools/extract-prompts install.sh) <(tools/extract-prompts SKILL.md)"
  exit 1
fi
exit 0
