#!/bin/bash
# Recovery-ladder + permission-decision tests for the checkpoint WRITE path
# (context-checkpoint.sh, registered PreToolUse).
#
# Covers:
#   R1-R3  the session_id recovery ladder (reacquire -> mint -> binding-wins)
#   D1-D2  permissionDecision uses the documented enum, never the invalid "block"
#
# Usage: bash .claude/hooks/tests/test-checkpoint-pretooluse-recovery.sh

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
assert_absent() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -q "$needle"; then _bad "$name"; else _ok "$name"; fi
}
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then _ok "$name"; else _bad "$name (got '$got' want '$want')"; fi
}

# Isolated project skeleton. Mirrors test-context-checkpoint-template.sh:10-13 so
# template resolution succeeds; without a resolvable template the hook's final
# emit path changes shape and every assertion here becomes meaningless.
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

# Drive the PreToolUse hook past its threshold. 99 clears any configured
# threshold (default 20 per context-checkpoint.sh:29).
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

# Same as run_cc but preserves FLAG/DONE, so a re-fire exercises the
# already-triggered path rather than a fresh trigger.
run_cc_noreset() {
  local proj="$1" sid="$2" term="$3"
  echo 99 > "/tmp/claude-context-pct-${sid}"
  jq -n --arg sid "$sid" --arg cwd "$proj" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Edit"}' | \
    USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null
}

cleanup_sid() {
  rm -f "/tmp/claude-context-pct-$1" "/tmp/claude-context-triggered-$1" \
        "/tmp/baton-pending-$1" "/tmp/baton-done-$1" "/tmp/baton-archive-$1" \
        "/tmp/claude-session-tracking-$1" "/tmp/baton-health-$1" "/tmp/baton-warned-$1"
}

echo "## context-checkpoint.sh recovery ladder"

# R1: session_id reverse-lookup wins when the terminal binding is absent.
run_r1() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-r1-$$"
  jq -n --arg sid "$sid" \
    '{workstream:"recovered-ws", display_name:"recovered", progress_file:"",
      phase:"impl", session_id:$sid, updated_at:"2026-07-01T00:00:00Z"}' \
    > "$tr/workstreams/recovered-ws.json"
  # No terminals/<hash>.json seeded - the binding is deliberately absent.
  local out; out=$(run_cc "$proj" "$sid" "RTerm")
  assert_contains "R1: reacquired workstream drives the write path" "$out" "progress-recovered-ws-"
  assert_absent   "R1: no unassociated path emitted" "$out" "progress-unassociated"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=RTerm term_hash)
  assert_eq "R1: terminal rebound onto the recovered workstream" \
    "$(jq -r '.workstream' "$tr/terminals/${th}.json" 2>/dev/null)" "recovered-ws"
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_r1

# R2: nothing to recover -> mint a fresh workstream, never write unassociated.
run_r2() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-r2-$$"
  local out; out=$(run_cc "$proj" "$sid" "MTerm")
  assert_absent "R2: no unassociated path emitted" "$out" "progress-unassociated"
  assert_eq "R2: exactly one workstream record was minted" \
    "$(ls "$tr/workstreams"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=MTerm term_hash)
  local bound; bound=$(jq -r '.workstream' "$tr/terminals/${th}.json" 2>/dev/null)
  if [ -n "$bound" ] && [ "$bound" != "null" ]; then
    _ok "R2: terminal bound to the minted workstream"
    assert_contains "R2: write path targets the minted workstream" "$out" "progress-${bound}-"
  else
    _bad "R2: terminal bound to the minted workstream"
    _bad "R2: write path targets the minted workstream"
  fi
  # The minted record must carry session_id so a later resume can reacquire it via R1.
  assert_eq "R2: minted record stamps session_id" \
    "$(jq -r '.session_id // empty' "$tr/workstreams/${bound}.json" 2>/dev/null)" "$sid"
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_r2

# R3: an existing terminal binding still wins - the ladder must not disturb it.
run_r3() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  local sid="sid-r3-$$"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=BTerm term_hash)
  jq -n '{terminal_id:"BTerm", workstream:"bound-ws", updated_at:"2026-07-01T00:00:00Z"}' \
    > "$tr/terminals/${th}.json"
  jq -n '{workstream:"bound-ws", display_name:"bound", progress_file:"", phase:"impl",
          updated_at:"2026-07-01T00:00:00Z"}' > "$tr/workstreams/bound-ws.json"
  # A DIFFERENT workstream carries this session_id; the terminal binding must win.
  jq -n --arg sid "$sid" \
    '{workstream:"decoy-ws", display_name:"decoy", progress_file:"", phase:"impl",
      session_id:$sid, updated_at:"2026-07-02T00:00:00Z"}' \
    > "$tr/workstreams/decoy-ws.json"
  local out; out=$(run_cc "$proj" "$sid" "BTerm")
  assert_contains "R3: existing terminal binding wins over session_id" "$out" "progress-bound-ws-"
  assert_eq "R3: binding left untouched" \
    "$(jq -r '.workstream' "$tr/terminals/${th}.json")" "bound-ws"
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_r3

echo "## context-checkpoint.sh permissionDecision validity"

# D1: the DONE guard must emit a value the harness accepts. "block" is NOT in the
# PreToolUse enum (allow|deny|ask|defer); emitting it fails the WHOLE payload
# validation, so the guard silently never fires. Verified against the shipped
# CLI binary. This test pins the documented value.
run_d1() {
  local proj; proj=$(mkproj)
  local sid="sid-d1-$$"
  echo 99 > "/tmp/claude-context-pct-${sid}"
  rm -f "/tmp/claude-context-triggered-${sid}"
  touch "/tmp/baton-done-${sid}"          # simulate: checkpoint already saved
  local out
  out=$(jq -n --arg sid "$sid" --arg cwd "$proj" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Edit"}' | \
    USER=u CLAUDE_TERMINAL_ID=DTerm CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_contains "D1: DONE guard fires" "$out" "Do NOT continue working"
  assert_contains "D1: DONE guard uses the documented deny value" "$out" '"deny"'
  assert_absent   "D1: DONE guard does not emit the invalid block value" "$out" '"block"'
  assert_contains "D1b: DONE guard puts its explanation in permissionDecisionReason" \
    "$out" '"permissionDecisionReason": "Checkpoint complete.'
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_d1

# C1: the subagent DONE guard must also explain itself.
# Drives the REAL branch: agent_id in the stdin JSON, plus the parent-sid,
# parent-pct and parent-DONE files the branch reads on its way to the guard.
# term_hash is md5("$USER:$CLAUDE_TERMINAL_ID"), so the parent-sid file must be
# named under the SAME USER the hook runs with - USER=u, as everywhere else here.
run_c1() {
  local proj; proj=$(mkproj)
  local sid="sid-c1-$$" psid="psid-c1-$$" term="term-c1-$$"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID="$term" \
    bash -c "source $HOOKS_DIR/lib/workstream-lib.sh; term_hash")
  printf '%s' "$psid" > "/tmp/claude-parent-sid-${th}"
  echo 99 > "/tmp/claude-context-pct-${psid}"
  touch "/tmp/baton-done-${psid}"
  local out
  out=$(jq -n --arg sid "$sid" --arg cwd "$proj" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Edit", agent_id:"agent-c1"}' | \
    USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_contains "C1: subagent guard explains itself in permissionDecisionReason" \
    "$out" '"permissionDecisionReason": "Parent session checkpoint complete.'
  assert_absent "C1b: C1 drove the SUBAGENT guard, not the main one" \
    "$out" 'Tell the user to /clear'
  rm -f "/tmp/claude-parent-sid-${th}"
  cleanup_sid "$sid"; cleanup_sid "$psid"; rm -rf "$proj"
}
run_c1

# D2: no permissionDecision anywhere in this hook may be the invalid "block".
run_d2() {
  local hits
  hits=$(grep -c 'permissionDecision: "block"' "$CC" || true)
  assert_eq "D2: no invalid block values remain in the hook" "$hits" "0"
}
run_d2

# P1: a present-but-malformed PCT must reach the health-warning path, not exit mute.
run_p1() {
  local proj; proj=$(mkproj)
  local sid="sid-p1-$$"
  local out=""
  echo "20.5" > "/tmp/claude-context-pct-${sid}"
  local i=1
  while [ "$i" -le 20 ]; do
    out=$(jq -n --arg sid "$sid" --arg cwd "$proj" \
      '{session_id:$sid, cwd:$cwd, tool_name:"Edit"}' | \
      USER=u CLAUDE_TERMINAL_ID="term-p1-$$" CLAUDE_PROJECT_DIR="$proj" \
      XDG_CONFIG_HOME="$proj/.config" \
      BATON_DIR="$proj/docs/sessions/.tracking" \
      BATON_PROGRESS_DIR="$proj/docs/sessions" \
      bash "$CC" 2>/dev/null)
    i=$((i+1))
  done
  assert_contains "P1: malformed PCT reaches the health warning" "$out" 'is not an integer'
  assert_contains "P1b: warning names the offending value" "$out" '20.5'
  cleanup_sid "$sid"
  rm -rf "$proj"
}
run_p1

# P1c: the ABSENT branch must keep its original wording. P1 and P1c are a pair -
# together they prove the classifier still tells the two causes apart. Asserting
# a shared prefix like "WARNING:" in both would pass even if the branches were
# collapsed into one message, which is the regression worth catching.
run_p1c() {
  local proj; proj=$(mkproj)
  local sid="sid-p1c-$$"
  local out=""
  rm -f "/tmp/claude-context-pct-${sid}"
  local i=1
  while [ "$i" -le 20 ]; do
    out=$(jq -n --arg sid "$sid" --arg cwd "$proj" \
      '{session_id:$sid, cwd:$cwd, tool_name:"Edit"}' | \
      USER=u CLAUDE_TERMINAL_ID="term-p1c-$$" CLAUDE_PROJECT_DIR="$proj" \
      XDG_CONFIG_HOME="$proj/.config" \
      BATON_DIR="$proj/docs/sessions/.tracking" \
      BATON_PROGRESS_DIR="$proj/docs/sessions" \
      bash "$CC" 2>/dev/null)
    i=$((i+1))
  done
  assert_contains "P1c: absent PCT keeps the 'not available' wording" "$out" 'not available'
  assert_absent   "P1d: absent PCT does not claim a malformed value" "$out" 'is not an integer'
  cleanup_sid "$sid"
  rm -rf "$proj"
}
run_p1c

# P2: an interrupted checkpoint turn must keep re-asserting, not go silent.
run_p2() {
  local proj; proj=$(mkproj)
  local sid="sid-p2-$$"
  local tr="$proj/docs/sessions/.tracking"
  run_cc "$proj" "$sid" "term-p2-$$" >/dev/null    # arms FLAG + PENDING
  local out2 out3 out4
  out2=$(run_cc_noreset "$proj" "$sid" "term-p2-$$")
  out3=$(run_cc_noreset "$proj" "$sid" "term-p2-$$")
  out4=$(run_cc_noreset "$proj" "$sid" "term-p2-$$")
  # P2 asserts the SOFT payload specifically, not the bare word CHECKPOINT.
  # 'CHECKPOINT' is a substring of BOTH arms ("CHECKPOINT STILL PENDING - " and
  # "CHECKPOINT STILL UNSAVED. "), so the loose form passes on an implementation
  # that denies from the very first re-fire - i.e. it cannot observe the nag
  # limit this step spends a paragraph justifying. P2f/P2g are the other half:
  # out2 and out3 are pre-limit fires (NAG=1 and NAG=2 against a limit of 3) and
  # must NOT deny. Without them, deleting the else arm entirely still passes.
  assert_contains "P2: re-fire re-asserts with the soft payload" "$out2" 'CHECKPOINT STILL PENDING'
  assert_absent   "P2f: does not deny before the limit" "$out2" '"permissionDecision": "deny"'
  assert_absent   "P2g: does not deny on the second re-fire either" "$out3" '"permissionDecision": "deny"'
  assert_contains "P2b: escalates to deny once the nag limit is reached" "$out4" '"permissionDecision": "deny"'
  assert_contains "P2c: pending-unsatisfied is recorded" \
    "$(cat "$tr/hook-events.jsonl" 2>/dev/null)" 'pending-unsatisfied'
  cleanup_sid "$sid"; rm -f "/tmp/baton-nag-${sid}"; rm -rf "$proj"
}
run_p2

# P2d: FLAG set + PENDING CLEARED is the state of EVERY session after a
# checkpoint has been successfully written. It must stay silent. This is the
# highest-blast-radius regression in the change: if the PENDING half of the
# re-arm condition is dropped or inverted, every post-checkpoint tool call for
# the rest of the session nags and then hard-denies at the limit, on sessions
# that did exactly what they were asked. Nothing else in the suite drives it.
run_p2d() {
  local proj; proj=$(mkproj)
  local sid="sid-p2d-$$"
  run_cc "$proj" "$sid" "term-p2d-$$" >/dev/null    # arms FLAG + PENDING
  rm -f "/tmp/baton-pending-${sid}"                 # the checkpoint was delivered
  local out
  out=$(run_cc_noreset "$proj" "$sid" "term-p2d-$$")
  assert_absent "P2d: satisfied checkpoint does not nag" "$out" 'CHECKPOINT STILL PENDING'
  assert_absent "P2e: satisfied checkpoint does not escalate to deny" "$out" 'CHECKPOINT STILL UNSAVED'
  cleanup_sid "$sid"; rm -f "/tmp/baton-nag-${sid}"; rm -rf "$proj"
}
run_p2d

# P2h: the hard deny must NEVER block the progress-file write itself. This hook
# is PreToolUse; PENDING is cleared only by checkpoint-write-trigger's PostToolUse
# AFTER a progress-*.md Write runs. So without the checkpoint-write exemption a
# re-fire at the nag limit denies the Write that would clear PENDING, deadlocking
# the checkpoint the nag demands. Drive a Write to a progress path with the nag
# already past the limit and assert it is allowed through.
run_p2h() {
  local proj; proj=$(mkproj)
  local sid="sid-p2h-$$"
  run_cc "$proj" "$sid" "term-p2h-$$" >/dev/null    # arms FLAG + PENDING
  echo 9 > "/tmp/baton-nag-${sid}"                  # already past the deny limit
  echo 99 > "/tmp/claude-context-pct-${sid}"
  local out
  out=$(jq -n --arg sid "$sid" --arg cwd "$proj" --arg fp "$proj/docs/sessions/progress-carry-ws.md" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' | \
    USER=u CLAUDE_TERMINAL_ID="term-p2h-$$" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_absent "P2h: nag never denies the progress-file write" "$out" '"permissionDecision": "deny"'
  # The exemption case has three arms (Write|Edit|MultiEdit) and PENDING is cleared
  # by a PostToolUse whose matcher is Write|Edit|MultiEdit, so a scaffold filled in
  # place via Edit/MultiEdit is a first-class PENDING-clearing path. Drive both at
  # the same over-limit state; a drifted arm here deadlocks exactly as a missing
  # Write arm would, and neither must be denied.
  local outE
  outE=$(jq -n --arg sid "$sid" --arg cwd "$proj" --arg fp "$proj/docs/sessions/progress-carry-ws.md" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$fp}}' | \
    USER=u CLAUDE_TERMINAL_ID="term-p2h-$$" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_absent "P2j: nag never denies an Edit to the progress file" "$outE" '"permissionDecision": "deny"'
  local outM
  outM=$(jq -n --arg sid "$sid" --arg cwd "$proj" --arg fp "$proj/docs/sessions/progress-carry-ws.md" \
    '{session_id:$sid, cwd:$cwd, tool_name:"MultiEdit", tool_input:{file_path:$fp}}' | \
    USER=u CLAUDE_TERMINAL_ID="term-p2h-$$" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_absent "P2k: nag never denies a MultiEdit to the progress file" "$outM" '"permissionDecision": "deny"'
  # A non-progress write at the same over-limit state MUST still be denied, or the
  # exemption is too wide and the nag has no teeth.
  local out2
  out2=$(jq -n --arg sid "$sid" --arg cwd "$proj" --arg fp "$proj/src/x.py" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' | \
    USER=u CLAUDE_TERMINAL_ID="term-p2h-$$" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    BATON_PROGRESS_DIR="$proj/docs/sessions" \
    bash "$CC" 2>/dev/null)
  assert_contains "P2i: non-progress write past the limit is still denied" "$out2" '"permissionDecision": "deny"'
  cleanup_sid "$sid"; rm -f "/tmp/baton-nag-${sid}"; rm -rf "$proj"
}
run_p2h

# P3: carry-forward must find the prior file under BATON_PROGRESS_DIR, and must
# not select the leftover scaffold (which is always newer than the real file).
run_p3() {
  local proj; proj=$(mktemp -d)
  local sid="sid-p3-$$" term="term-p3-$$"
  local ws="carry-ws"
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals" "$proj/share/templates" "$proj/.config/baton"
  # task.md is the template that actually carries <<ARCHIVED_CHECKBOXES>>.
  cp "$HOOKS_DIR/../../share/templates/task.md"   "$proj/share/templates/task.md"
  cp "$HOOKS_DIR/../../share/templates/task.json" "$proj/share/templates/task.json"
  echo '{"template": "task"}' > "$proj/.config/baton/config.json"
  git -C "$proj" init -q 2>/dev/null
  jq -n --arg ws "$ws" '{workstream:$ws, display_name:$ws, progress_file:"",
    phase:"unknown", updated_at:"2026-07-18T00:00:00Z", project_dir:"x"}' \
    > "$tr/workstreams/${ws}.json"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID="$term" bash -c 'source '"$HOOKS_DIR"'/lib/workstream-lib.sh; term_hash')
  jq -n --arg ws "$ws" '{terminal_id:"t", workstream:$ws, updated_at:"2026-07-18T00:00:00Z"}' \
    > "$tr/terminals/${th}.json"
  printf '## Archived\n- [x] real prior item\n' > "$proj/docs/sessions/progress-${ws}-aaa111.md"
  sleep 1
  printf '## Archived\n- [x] SCAFFOLD LEFTOVER\n' > "$proj/docs/sessions/progress-${ws}-aaa111.scaffold.md"
  run_cc "$proj" "$sid" "$term" >/dev/null
  # Named, not globbed: both scaffolds match the glob and head -1 is lexicographic.
  local rendered="$proj/docs/sessions/progress-${ws}-${th}.scaffold.md"
  if [ ! -f "$rendered" ]; then
    _bad "P3: hook did not render a scaffold at the expected path ($rendered)"
  fi
  local body; body=$(cat "$rendered" 2>/dev/null)
  assert_contains "P3: carry-forward sourced the real prior file" "$body" 'real prior item'
  assert_absent   "P3b: carry-forward did not source the scaffold" "$body" 'SCAFFOLD LEFTOVER'
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_p3

# P3c: the ARCHIVE FALLBACK. P3 plants a file in the ACTIVE dir, so $newest is
# non-empty and the `if [ -z "$newest" ]` branch never runs - under P3 or any
# other case in this suite. That leaves the entire find-on-$archive_root half of
# step 7's fix executed by NO test, and its failure mode is silent: an empty
# result renders `None yet`, V8 stays satisfied, nothing goes red. That is the
# exact signature of finding B1, re-created inside the code that fixes B1.
# This case omits the active-dir file so the fallback is the ONLY way to succeed.
run_p3c() {
  local proj; proj=$(mktemp -d)
  local sid="sid-p3c-$$" term="term-p3c-$$"
  local ws="carry-ws"
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals" "$proj/share/templates" "$proj/.config/baton"
  cp "$HOOKS_DIR/../../share/templates/task.md"   "$proj/share/templates/task.md"
  cp "$HOOKS_DIR/../../share/templates/task.json" "$proj/share/templates/task.json"
  echo '{"template": "task"}' > "$proj/.config/baton/config.json"
  git -C "$proj" init -q 2>/dev/null
  jq -n --arg ws "$ws" '{workstream:$ws, display_name:$ws, progress_file:"",
    phase:"unknown", updated_at:"2026-07-18T00:00:00Z", project_dir:"x"}' \
    > "$tr/workstreams/${ws}.json"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID="$term" bash -c 'source '"$HOOKS_DIR"'/lib/workstream-lib.sh; term_hash')
  jq -n --arg ws "$ws" '{terminal_id:"t", workstream:$ws, updated_at:"2026-07-18T00:00:00Z"}' \
    > "$tr/terminals/${th}.json"
  # DELIBERATELY no progress-${ws}-*.md in $proj/docs/sessions - an active-dir
  # file would make $newest non-empty and skip the branch under test.
  # Fixed month directory, NOT $(date +%Y-%m): find recurses, so any depth
  # matches, and a date-derived name would rot at a month boundary.
  mkdir -p "$proj/archive/progress/2026-01"
  printf '## Archived\n- [x] archived prior item\n' \
    > "$proj/archive/progress/2026-01/progress-${ws}-bbb222.md"
  run_cc "$proj" "$sid" "$term" >/dev/null
  local rendered="$proj/docs/sessions/progress-${ws}-${th}.scaffold.md"
  local body; body=$(cat "$rendered" 2>/dev/null)
  assert_contains "P3c: carry-forward falls back to the archive root" "$body" 'archived prior item'
  cleanup_sid "$sid"; rm -rf "$proj"
}
run_p3c

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
