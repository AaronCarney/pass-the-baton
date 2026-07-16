#!/usr/bin/env bash
# cleanup-on-exit.sh must sweep the E6 relaunch driver's per-session
# .relaunch-fired marker, and must NEVER sweep the terminal-keyed relaunch
# REQUEST marker - its survival across SessionEnd is the whole mechanism: the
# supervisor reads that marker AFTER the session has exited, so sweeping it on
# SessionEnd would silently disarm every relaunch.
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLE="$HOOKS_DIR/cleanup-on-exit.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

proj=$(mktemp -d); tracking="$proj/docs/sessions/.tracking"
mkdir -p "$tracking/terminals" "$tracking/workstreams" "$proj/archive"
SID="sid-rfc-$$"
OTHER="sid-rfc-other-$$"
REQ="/tmp/baton-relaunch-$(USER=u CLAUDE_TERMINAL_ID=TC-rfc term_hash)"

run_cleanup(){
  USER=u CLAUDE_TERMINAL_ID=TC-rfc CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" BATON_ARCHIVE_DIR="$proj/archive" \
    bash "$CLE" <<<'{"session_id":"'"$1"'","cwd":"'"$proj"'"}' >/dev/null 2>&1
}
cleanup_tmp(){ rm -f "/tmp/baton-done-$SID" /tmp/baton-done-"$SID".* \
  "/tmp/baton-done-$OTHER" /tmp/baton-done-"$OTHER".* "$REQ" \
  "/tmp/claude-session-tracking-$SID"; }
trap 'cleanup_tmp; rm -rf "$proj"' EXIT

# --- 1. planted markers: the sweep must take all three, scoped to this session
cleanup_tmp
touch "/tmp/baton-done-$SID" "/tmp/baton-done-$SID.fired" "/tmp/baton-done-$SID.relaunch-fired"
touch "/tmp/baton-done-$OTHER.relaunch-fired"
run_cleanup "$SID"
assert "done-swept"              "[ ! -e /tmp/baton-done-$SID ]"
assert "fired-swept"             "[ ! -e /tmp/baton-done-$SID.fired ]"
assert "relaunch-fired-swept"    "[ ! -e /tmp/baton-done-$SID.relaunch-fired ]"
assert "other-session-untouched" "[ -e /tmp/baton-done-$OTHER.relaunch-fired ]"

# --- 2. drive the REAL Stop hook so IT names the marker. This case never types
# the literal - it is the only one that grades this sweep against the actual
# producer rather than against its own spelling.
cleanup_tmp
: > "/tmp/baton-done-$SID"
: > "$REQ"
echo '{"session_id":"'"$SID"'","cwd":"/tmp"}' | \
  AGENT_SESSION_ID= BATON_AUTO_CONTINUE_MODE=relaunch BATON_RELAUNCH_SUPERVISOR=$$ \
  BATON_RELAUNCH_REQ="$REQ" BATON_RELAUNCH_BIN=/bin/true \
  bash "$HOOKS_DIR/stop-relaunch-trigger.sh" >/dev/null 2>&1
# armed-first, or a hook that armed nothing makes the next assert vacuous
assert "hook-armed-something" "[ -n \"\$(ls /tmp/baton-done-$SID.* 2>/dev/null)\" ]"
run_cleanup "$SID"
assert "hook-marker-swept"    "[ -z \"\$(ls /tmp/baton-done-$SID.* 2>/dev/null)\" ]"

# --- 3. load-bearing: the relaunch REQUEST marker must SURVIVE SessionEnd.
# The supervisor reads it after this hook runs. See design :119-120.
cleanup_tmp
: > "$REQ"
run_cleanup "$SID"
assert "request-marker-SURVIVES" "[ -e \"$REQ\" ]"

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
