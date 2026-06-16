#!/bin/bash
# Unit tests for share/logrotate.d/baton snippet + install step (E7-T4).
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
SNIPPET="$REPO_DIR/share/logrotate.d/baton"
INSTALL_SH="$REPO_DIR/tools/install.sh"

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

echo "## share/logrotate.d/baton"

assert "SNIPPET-EXISTS: file present" "[ -f '$SNIPPET' ]"
assert "SNIPPET-NO-SHEBANG: not a shell script" "! head -1 '$SNIPPET' | grep -q '^#!'"

# 11 required directives - check each.
for d in 'daily' 'rotate 30' 'missingok' 'notifempty' '^[[:space:]]*compress$' \
         'compresscmd /usr/bin/zstd' 'compressext \.zst' 'compressoptions "-19 -T0 --rm"' \
         'delaycompress' 'copytruncate' 'su "\$USER" "\$USER"'; do
  assert "SNIPPET-DIRECTIVE: $d present" "grep -Eq '$d' '$SNIPPET'"
done

assert "SNIPPET-ZSTD-EXACT: compresscmd /usr/bin/zstd exact match" \
  "grep -Fxq '    compresscmd /usr/bin/zstd' '$SNIPPET'"

echo ""
echo "## tools/install.sh - logrotate step"

assert "INSTALL-MARKER: E7-T4 insertion point named" \
  "grep -q 'E7-T4: logrotate install' '$INSTALL_SH'"

# Idempotency: run install.sh twice with a writable fake /etc/logrotate.d
# Use --non-interactive against a temp target and override the install dest via env.
run_idempotency() {
  local d t
  d=$(mktemp -d)
  t=$(mktemp -d)
  # Sandbox all install-side dirs into the test tmpdir so a developer running
  # this test locally doesn't get an unsolicited shim copy in their real
  # ~/.claude/. install.sh derives SHIM_DEST_DIR from CLAUDE_PROJECT_DIR (and
  # falls back to $HOME/.claude); SETTINGS defaults to $HOME/.claude; the
  # FS-type probe reads $XDG_STATE_HOME. Pin all three to $t.
  HOME="$t" XDG_STATE_HOME="$t/.local/state" CLAUDE_PROJECT_DIR="$t" \
    BATON_LOGROTATE_DEST_DIR="$d" \
    bash "$INSTALL_SH" --non-interactive --target "$t" --settings "$t/settings.json" >/dev/null 2>&1 || true
  local first_sum=""
  [ -f "$d/baton" ] && first_sum=$(md5sum "$d/baton" | awk '{print $1}')
  HOME="$t" XDG_STATE_HOME="$t/.local/state" CLAUDE_PROJECT_DIR="$t" \
    BATON_LOGROTATE_DEST_DIR="$d" \
    bash "$INSTALL_SH" --non-interactive --target "$t" --settings "$t/settings.json" >/dev/null 2>&1 || true
  local second_sum=""
  [ -f "$d/baton" ] && second_sum=$(md5sum "$d/baton" | awk '{print $1}')
  assert "INSTALL-IDEMPOTENT: file present after first run" "[ -n '$first_sum' ]"
  assert "INSTALL-IDEMPOTENT: file unchanged after second run" "[ '$first_sum' = '$second_sum' ]"
  # Count entries - only one file, never duplicated.
  local count
  count=$(find "$d" -maxdepth 1 -name 'baton*' | wc -l)
  assert "INSTALL-IDEMPOTENT: exactly one snippet file (no duplicates)" "[ '$count' = '1' ]"
  rm -rf "$d" "$t"
}
run_idempotency

echo ""
echo "PASS $PASSED / FAIL $FAILED"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed: ${FAILED_CASES[*]}"
  exit 1
fi
exit 0
