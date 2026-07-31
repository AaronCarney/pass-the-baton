#!/usr/bin/env bash
# The dashboard's interactive mode must be documented, and no tracked doc may
# claim it is equivalent to `show`. Three documents described baton-dashboard.sh
# as show/set only for two releases after the TUI shipped, and one of them
# annotated the bare invocation as "interactive - currently same as `show`",
# which was wrong twice over: the bare form runs `show` and is not interactive,
# and the real interactive mode lives under a separate `tui` verb.
#
# Facts are checked against tools/baton-dashboard-tui.sh, not against the
# CHANGELOG. Usage: bash .claude/hooks/tests/test-dashboard-docs.sh
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

cd "$REPO" || exit 1

CLI=docs/cli.md
SKILL=.claude/skills/baton/SKILL.md
TUI=tools/baton-dashboard-tui.sh
DISPATCH=tools/baton-dashboard.sh

# 1. The retired false claim must not come back, in any tracked doc.
ok "no doc claims the interactive mode is the same as show" \
  "! grep -rqF 'currently same as' README.md docs/*.md $SKILL"

# 2. The three user-facing docs each name the tui verb. SKILL.md invokes the
#    tool through ${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}, so its command
#    line reads `baton-dashboard.sh" tui` with the closing quote between the
#    two words. Match the optional quote rather than the bare literal, or this
#    assertion passes only by accident on some other line of the file.
for f in README.md "$CLI" "$SKILL"; do
  ok "$f documents the tui subcommand" "grep -qE 'baton-dashboard[.]sh\"? tui' '$f'"
done
# The docs above only prove the docs agree with themselves. Cross-check that the
# dispatcher still accepts the documented verb, so renaming the case arm fails
# here instead of leaving every doc pointing at a dead command. Match tui at any
# position in the arm: reordering the alternatives keeps the verb accepted, and
# this assertion claims acceptance, not position.
ok "the dispatcher still accepts the tui verb" \
  "grep -qE '(^ +|[|])tui[|)]' '$DISPATCH'"

# 3. Every tab name in the script is documented in the CLI reference's
#    interactive-mode section. Read the names out of _TUI_TABS so a renamed tab
#    fails here instead of drifting, and confine the search to that section so a
#    tab renamed to a common word that already appears elsewhere in cli.md
#    cannot pass vacuously.
tabs=$(sed -n 's/^_TUI_TABS=(\(.*\))$/\1/p' "$TUI" | tr -d '"')
ok "tab list parsed from the script" "[ -n \"$tabs\" ]"
SECT=$(mktemp)
trap 'rm -f "$SECT"' EXIT
sed -n '/^### Interactive mode/,/^### Safety/p' "$CLI" > "$SECT"
ok "docs/cli.md has an interactive mode section" "[ -s \"$SECT\" ]"
for t in $tabs; do
  ok "docs/cli.md documents the $t tab" "grep -qF '$t' \"$SECT\""
done

# 4. Every read-only key the Config tab excludes is named in the read-only
#    paragraph. Read the key set out of _tui_key_readonly so a changed exclusion
#    set fails here instead of drifting, and confine the search to that one
#    paragraph: BATON_DIR and BATON_PROJECT_DIR also appear in the Config-tab
#    table row, so a whole-file grep would pass even if the read-only paragraph
#    were deleted outright.
rokeys=$(sed -n 's/^_tui_key_readonly().* in \([^)]*\)) return 0.*/\1/p' "$TUI" | tr '|' ' ')
ok "read-only key set parsed from the script" "[ -n \"$rokeys\" ]"
RO=$(mktemp)
trap 'rm -f "$SECT" "$RO"' EXIT
sed -n '/\*\*read-only\*\*/,/^$/p' "$CLI" > "$RO"
ok "docs/cli.md has a read-only paragraph" "[ -s \"$RO\" ]"
for k in $rokeys; do
  ok "docs/cli.md names $k as read-only" "grep -qF '$k' \"$RO\""
done

# 5. /baton's own SKILL.md carries the terminal requirement, so the skill can
#    never tell an agent to run the TUI inside a session.
ok "SKILL.md states the TUI needs a real TTY" \
  "grep -qiE 'TTY|real terminal' '$SKILL'"

# 6. The install doc names all three installed surfaces, not just two.
ok "docs/install.md names commands alongside hooks and skills" \
  "grep -qF 'hooks, skills, and commands' docs/install.md"
ok "docs/install.md no longer stops at hooks + skills" \
  "! grep -qF 'hooks + skills' docs/install.md"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
