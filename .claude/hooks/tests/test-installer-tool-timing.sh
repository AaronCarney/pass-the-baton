#!/bin/bash
# Tests for install.sh tool-timing hook wiring.
# Mirrors test-installer-post-tool-batch.sh - extracts the marker-bounded
# block and runs it in a sandboxed HOME.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
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

run_install_block() {
  local fake_home="$1" install_prefix="$2" stderr_file="${3:-/dev/null}"
  local block_file; block_file=$(mktemp /tmp/install-tt-block.XXXXXX.sh)
  awk '/# tool-timing hook register begin/{found=1; next}
       /# tool-timing hook register end/{found=0; next}
       found' "$INSTALL_SH" > "$block_file"
  HOME="$fake_home" \
    INSTALL_PREFIX="$install_prefix" \
    SETTINGS="$fake_home/.claude/settings.json" \
    bash "$block_file" 2>"$stderr_file"
  local rc=$?
  rm -f "$block_file"
  return $rc
}

echo "## tools/install.sh - tool-timing hook wiring"

# --- marker presence ---------------------------------------------------------
assert "INSTALL-MARKER: tool-timing begin marker present" \
  "grep -q 'tool-timing hook register begin' '$INSTALL_SH'"
assert "INSTALL-MARKER: tool-timing end marker present" \
  "grep -q 'tool-timing hook register end' '$INSTALL_SH'"

# --- empty settings.json → PostToolUse entry added ---------------------------
run_empty_settings() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  local cmd
  cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$d/.claude/settings.json" 2>/dev/null)
  assert "EMPTY-SETTINGS: command ends in /tool-timing.sh" \
    "[[ '$cmd' == */tool-timing.sh ]]"
  rm -rf "$d"
}
run_empty_settings

# --- coexists with pre-existing PostToolUse entries (different command) ------
run_coexist_with_other_post_tool_use() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  # Pre-existing PostToolUse for checkpoint-write-trigger (different matcher).
  cat > "$d/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{"type": "command", "command": "/repo/.claude/hooks/checkpoint-write-trigger.sh"}]
      }
    ]
  }
}
JSON
  run_install_block "$d" "$prefix"
  local count
  count=$(jq '.hooks.PostToolUse | length' "$d/.claude/settings.json" 2>/dev/null)
  assert "COEXIST: now 2 PostToolUse entries (checkpoint-write + tool-timing)" \
    "[ '$count' = '2' ]"
  assert "COEXIST: checkpoint-write-trigger entry preserved" \
    "jq -e '.hooks.PostToolUse[0].hooks[0].command==\"/repo/.claude/hooks/checkpoint-write-trigger.sh\"' '$d/.claude/settings.json' >/dev/null 2>&1"
  rm -rf "$d"
}
run_coexist_with_other_post_tool_use

# --- idempotency: running twice does not duplicate ---------------------------
run_idempotent() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  run_install_block "$d" "$prefix"
  local count
  count=$(jq '.hooks.PostToolUse | length' "$d/.claude/settings.json" 2>/dev/null)
  assert "IDEMPOTENT: exactly 1 tool-timing entry after 2 runs" "[ '$count' = '1' ]"
  rm -rf "$d"
}
run_idempotent

# --- missing settings.json → file created -----------------------------------
run_missing_settings() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  run_install_block "$d" "$prefix"
  assert "MISSING-SETTINGS: settings.json created" "[ -f '$d/.claude/settings.json' ]"
  assert "MISSING-SETTINGS: contains tool-timing PostToolUse entry" \
    "jq -e '.hooks.PostToolUse | length > 0' '$d/.claude/settings.json' >/dev/null 2>&1"
  rm -rf "$d"
}
run_missing_settings

# --- stderr contains the opt-in hint -----------------------------------------
run_stderr_message() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  local err; err=$(mktemp)
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix" "$err"
  assert "STDERR-MSG: 'registered tool-timing hook' in stderr" \
    "grep -q 'registered tool-timing hook' '$err'"
  assert "STDERR-MSG: opt-in hint mentions BATON_TIMING=1" \
    "grep -q 'BATON_TIMING=1' '$err'"
  rm -rf "$d" "$err"
}
run_stderr_message

# --- file mode after install is 0644 -----------------------------------------
run_file_mode() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  local mode; mode=$(stat -c '%a' "$d/.claude/settings.json" 2>/dev/null)
  assert "FILE-MODE: settings.json mode is 0644 after install" "[ '$mode' = '644' ]"
  rm -rf "$d"
}
run_file_mode

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
