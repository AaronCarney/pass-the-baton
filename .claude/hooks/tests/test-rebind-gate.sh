#!/usr/bin/env bash
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PD="$HOOKS_DIR/project-detect.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
setup(){ # $1=current-ws-shape(fresh|established)
  proj=$(mktemp -d); tracking="$proj/docs/sessions/.tracking"
  mkdir -p "$tracking/terminals" "$tracking/workstreams" "$proj/projects"
  ln -s /tmp "$proj/projects/stellaris"   # a project symlink named 'stellaris'
  # existing target ws named 'stellaris'
  jq -n '{workstream:"ws-stellaris",display_name:"stellaris",progress_file:"/p.md",phase:"implementation",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/workstreams/ws-stellaris.json"
  # current ws bound to THIS terminal
  if [ "$1" = fresh ]; then
    jq -n '{workstream:"ws-cur",display_name:"cur",progress_file:"",phase:"unknown",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/workstreams/ws-cur.json"
  else
    jq -n '{workstream:"ws-cur",display_name:"cur",progress_file:"/c.md",phase:"implementation",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/workstreams/ws-cur.json"
  fi
  th=$(USER=u CLAUDE_TERMINAL_ID=TR term_hash)
  jq -n --arg th "$th" '{terminal_id:"TR",workstream:"ws-cur",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/terminals/${th}.json"
  echo "$tracking/terminals/${th}.json" > "/tmp/claude-session-tracking-SIDPD"
}
run(){ USER=u CLAUDE_TERMINAL_ID=TR CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
  bash "$PD" <<<'{"session_id":"SIDPD","cwd":"'"$proj"'","prompt":"lets work on stellaris"}' 2>/dev/null; }
cur_ws(){ jq -r .workstream "$tracking/terminals/${th}.json"; }

# Case A: established current ws -> NO rebind + hint printed, exit 0
setup established; out=$(run); rc=$?
assert "established-no-rebind" "[ \"\$(cur_ws)\" = ws-cur ]"
assert "established-hint" "echo \"\$out\" | grep -qi 'WORKSTREAM='"
assert "established-exit0" "[ $rc -eq 0 ]"
rm -rf "$proj"; rm -f /tmp/claude-session-tracking-SIDPD
# Case B: fresh current ws -> rebinds to ws-stellaris
setup fresh; run >/dev/null
assert "fresh-rebinds" "[ \"\$(cur_ws)\" = ws-stellaris ]"
rm -rf "$proj"; rm -f /tmp/claude-session-tracking-SIDPD
# Case C: fresh current ws but target at cap -> NO rebind + notice
setup fresh
thc=$(USER=u CLAUDE_TERMINAL_ID=OTHER term_hash)
jq -n '{terminal_id:"OTHER",workstream:"ws-stellaris",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/terminals/${thc}.json"
out=$(BATON_MAX_TERMINALS_PER_WORKSTREAM=1 USER=u CLAUDE_TERMINAL_ID=TR CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" bash "$PD" <<<'{"session_id":"SIDPD","cwd":"'"$proj"'","prompt":"stellaris"}' 2>/dev/null)
assert "cap-blocks-rebind" "[ \"\$(cur_ws)\" = ws-cur ]"
assert "cap-notice" "echo \"\$out\" | grep -qi 'max'"
rm -rf "$proj"; rm -f /tmp/claude-session-tracking-SIDPD
# Case D: roster set-diff notify - established terminal stays put; notice fires when a co-tenant joins the current ws
setup established
base=$(run)
assert "D-baseline-silent" "! echo \"\$base\" | grep -qi 'roster changed'"
thd=$(USER=u CLAUDE_TERMINAL_ID=COT term_hash)
jq -n '{terminal_id:"COT",workstream:"ws-cur",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/terminals/${thd}.json"
out=$(run)
assert "D-roster-change-notice" "echo \"\$out\" | grep -qi 'roster changed'"
rm -rf "$proj"; rm -f /tmp/claude-session-tracking-SIDPD
# Case E: cap>0 with room -> fresh terminal STILL rebinds (positive cap path, _n < _cap arm)
setup fresh
thr=$(USER=u CLAUDE_TERMINAL_ID=ROOM term_hash)
jq -n '{terminal_id:"ROOM",workstream:"ws-stellaris",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tracking/terminals/${thr}.json"
BATON_MAX_TERMINALS_PER_WORKSTREAM=2 USER=u CLAUDE_TERMINAL_ID=TR CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" bash "$PD" <<<'{"session_id":"SIDPD","cwd":"'"$proj"'","prompt":"stellaris"}' >/dev/null 2>&1
assert "cap-room-rebinds" "[ \"\$(cur_ws)\" = ws-stellaris ]"
rm -rf "$proj"; rm -f /tmp/claude-session-tracking-SIDPD
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
