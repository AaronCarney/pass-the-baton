#!/bin/bash
# The checkpoint write path must never name a file that already exists.
#
# Claude Code refuses a Write that overwrites a file the session has not Read
# ("File has not been read yet"), so a destination reused across checkpoints
# costs a failed write plus a full re-read of the stale progress file - at the
# exact moment context is at threshold. The model needs none of that content:
# context-checkpoint.sh pre-renders every carry-forward into the scaffold.
#
# Usage: bash .claude/hooks/tests/test-checkpoint-write-path-uniqueness.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CC="$HOOKS_DIR/context-checkpoint.sh"

PASS=0
FAIL=0
FAILED_CASES=()

_ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
_bad() { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  FAIL  $1"; }

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -q "$needle"; then _ok "$name"; else _bad "$name"; fi
}

# Project skeleton mirrors test-checkpoint-pretooluse-recovery.sh:mkproj - without
# a resolvable template the hook takes a different emit path and every assertion
# below stops meaning anything.
mkproj() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking/workstreams" \
           "$d/docs/sessions/.tracking/terminals" \
           "$d/share/templates" "$d/.config/baton"
  cp "$HOOKS_DIR/../../share/templates/free.md" "$d/share/templates/free.md" 2>/dev/null \
    || echo '# stub free template' > "$d/share/templates/free.md"
  echo '{"template": "free"}' > "$d/.config/baton/config.json"
  git -C "$d" init -q 2>/dev/null
  printf '%s' "$d"
}

run_cc() {
  local proj="$1" sid="$2" term="$3"
  echo 99 > "/tmp/claude-context-pct-${sid}"
  rm -f "/tmp/claude-context-triggered-${sid}" "/tmp/baton-done-${sid}"
  jq -n --arg sid "$sid" --arg cwd "$proj" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Edit"}' | \
    USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    BATON_ARCHIVE_DIR="$proj/archive" \
    bash "$CC" 2>/dev/null
}

# The instruction block names the destination on the line after "EXACTLY this path:".
emitted_path() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    | grep -A1 'EXACTLY this path' | tail -1 | tr -d ' \t'
}

seed_ws() {
  local tr="$1" ws="$2" sid="$3" term="$4"
  jq -n --arg sid "$sid" --arg ws "$ws" \
    '{workstream:$ws, display_name:$ws, progress_file:"", phase:"impl",
      session_id:$sid, updated_at:"2026-07-01T00:00:00Z"}' \
    > "$tr/workstreams/${ws}.json"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID="$term" bash -c 'source '"$HOOKS_DIR"'/lib/workstream-lib.sh; term_hash')
  jq -n --arg ws "$ws" '{terminal_id:"t", workstream:$ws, updated_at:"2026-07-01T00:00:00Z"}' \
    > "$tr/terminals/${th}.json"
  printf '%s' "$th"
}

cleanup_sid() {
  rm -f "/tmp/claude-context-pct-$1" "/tmp/claude-context-triggered-$1" \
        "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/baton-archive-$1" \
        "/tmp/claude-session-tracking-$1" "/tmp/baton-health-$1" "/tmp/baton-warned-$1"
}

echo "## checkpoint write-path uniqueness"

# W1: a prior checkpoint for this same terminal already left a file behind. The
# next destination must not be that file - otherwise the model's Write is
# rejected until it reads the stale file back in.
run_w1() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-w1-$$" ws="uniq-ws" term="UTerm1"
  local th; th=$(seed_ws "$tr" "$ws" "$sid" "$term")
  # Prior checkpoint output, written under the pre-fix per-terminal name.
  printf '## Archived\n- [x] prior item\n' > "$proj/docs/sessions/progress-${ws}-${th}.md"
  local out; out=$(run_cc "$proj" "$sid" "$term")
  local p; p=$(emitted_path "$out")
  if [ -n "$p" ]; then _ok "W1: hook emitted a write path"; else _bad "W1: hook emitted a write path"; fi
  if [ -n "$p" ] && [ ! -e "$p" ]; then
    _ok "W1: write path does not name an existing file"
  else
    _bad "W1: write path does not name an existing file (got '$p')"
  fi
  # Compatibility: the cross-workstream guard in checkpoint-write-trigger.sh
  # anchors on the progress-<ws>- prefix, and the archive-marking loop keys on
  # the terminal hash. Both must survive whatever uniqueness scheme is used.
  assert_contains "W1: basename keeps the progress-<ws>- prefix" "$(basename "${p:-x}")" "^progress-${ws}-"
  assert_contains "W1: basename still carries the terminal hash" "$(basename "${p:-x}")" "$th"
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_w1

# W2: back-to-back checkpoints in one terminal must not collide. Each fire
# materializes its file, exactly as the model's Write would.
run_w2() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-w2-$$" ws="uniq-ws2" term="UTerm2"
  seed_ws "$tr" "$ws" "$sid" "$term" >/dev/null
  local p1 p2
  p1=$(emitted_path "$(run_cc "$proj" "$sid" "$term")")
  [ -n "$p1" ] && printf '## Archived\n- [x] first\n' > "$p1"
  # Same second-resolution clock is plausible here; the scheme must still not
  # hand back a path that now exists.
  p2=$(emitted_path "$(run_cc "$proj" "$sid" "$term")")
  if [ -n "$p2" ] && [ "$p1" != "$p2" ] && [ ! -e "$p2" ]; then
    _ok "W2: second checkpoint gets a fresh path"
  else
    _bad "W2: second checkpoint gets a fresh path (p1='$p1' p2='$p2')"
  fi
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_w2

# W3: the scaffold is derived from the write path, so it must track it. A
# scaffold left at a stale name would be read as this checkpoint's reference.
run_w3() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-w3-$$" ws="uniq-ws3" term="UTerm3"
  seed_ws "$tr" "$ws" "$sid" "$term" >/dev/null
  local out; out=$(run_cc "$proj" "$sid" "$term")
  local p; p=$(emitted_path "$out")
  local scaffold="${p%.md}.scaffold.md"
  if [ -n "$p" ] && [ -s "$scaffold" ]; then
    _ok "W3: scaffold is rendered alongside the emitted write path"
  else
    _bad "W3: scaffold is rendered alongside the emitted write path (want '$scaffold')"
  fi
  assert_contains "W3: instruction points at that scaffold" "$out" "$(basename "$scaffold")"
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_w3

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
