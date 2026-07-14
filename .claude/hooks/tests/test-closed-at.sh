#!/usr/bin/env bash
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLE="$HOOKS_DIR/cleanup-on-exit.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
proj=$(mktemp -d); tracking="$proj/docs/sessions/.tracking"; mkdir -p "$tracking/terminals" "$tracking/workstreams"
th=$(USER=u CLAUDE_TERMINAL_ID=TC term_hash)
jq -n --arg ws ws-x '{terminal_id:"TC",workstream:$ws,updated_at:"2026-05-05T00:00:00Z"}' > "$tracking/terminals/${th}.json"
USER=u CLAUDE_TERMINAL_ID=TC CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
  bash "$CLE" <<<'{"session_id":"sid-ce","cwd":"'"$proj"'"}' >/dev/null 2>&1
assert "binding-preserved" "[ -f \"$tracking/terminals/${th}.json\" ]"
assert "closed_at-stamped" "[ -n \"\$(jq -r '.closed_at // empty' \"$tracking/terminals/${th}.json\")\" ]"
assert "workstream-preserved" "[ \"\$(jq -r '.workstream' \"$tracking/terminals/${th}.json\")\" = ws-x ]"
rm -rf "$proj"; rm -f "/tmp/claude-session-tracking-sid-ce"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
