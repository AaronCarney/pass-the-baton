#!/bin/bash
# INVARIANT: every terminal failure path in checkpoint-write-trigger.sh must
# emit a top-level {"decision":"block"}. hookSpecificOutput.permissionDecision
# does not exist for PostToolUse and is silently stripped, so a failure that
# emits only additionalContext does not block - the model proceeds and tells the
# user to /clear on top of an unsaved session.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WT="$HOOKS_DIR/checkpoint-write-trigger.sh"

# Pin the active template. Without this the lint pipeline resolves whatever
# template the DEVELOPER has configured in ~/.config/baton/config.json (see
# tpl::resolve_active_template precedence 2), so B3's rendered fixture would
# fail V1/V8 against an unexpected template and die at the lint instead of
# reaching the pointer write. BATON_TEMPLATE_PATH is precedence 1 and bypasses
# config entirely.
TPL="$HOOKS_DIR/../../share/templates/free.md"
export BATON_TEMPLATE_PATH="$TPL"

# Pin XDG_CONFIG_HOME for the same reason, on a DIFFERENT key. _cfg::get reads
# "${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json" (workstream-lib.sh:21),
# and derive_display_name is _cfg::get BATON_DISPLAY_NAME <fallback> display_name.
# So a `display_name` key in the executing developer's own config outranks the
# fallback argument, and B7 - the ONLY behavioural evidence for E3 - would pass
# whether or not step 6(a)'s fix is present. Nothing fails on the machine this
# was written on (that config holds only BATON_TIMING and BATON_COLLECT), which
# is exactly the problem: the evidence is machine-dependent and unpinned.
# run_wt pins it per-invocation below; this export covers the helper subshells.
# Pinned UNCONDITIONALLY - a `${XDG_CONFIG_HOME:-...}` default would preserve the
# developer's own value and change nothing.
# Precedent: test-checkpoint-pretooluse-recovery.sh:60 and :161 both pin it.
export XDG_CONFIG_HOME="$(mktemp -d)/cfg"

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
_bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

assert_blocks() {
  local name="$1" payload="$2"
  if printf '%s' "$payload" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    _ok "$name"
  else
    _bad "$name (payload: $(printf '%s' "$payload" | head -c 200))"
  fi
}

mkproj() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.baton/workstreams" "$d/.baton/terminals" "$d/.baton/progress"
  printf '%s' "$d"
}

bind_ws() {
  local proj="$1" ws="$2" term="$3"
  # term_hash is md5("${USER}:${source_val}") (workstream-lib.sh:83). The hook is
  # invoked below with USER=u, so this MUST compute the hash under the same USER
  # or the record lands at a path the hook never looks at, the bind silently
  # fails, and every case here degrades to the no-workstream path instead of
  # testing what it names. Matches test-checkpoint-pretooluse-recovery.sh:88.
  local th; th=$(USER=u CLAUDE_TERMINAL_ID="$term" bash -c "source $HOOKS_DIR/lib/workstream-lib.sh; term_hash")
  jq -n --arg ws "$ws" '{terminal_id:"t", workstream:$ws, updated_at:"2026-07-18T00:00:00Z"}' \
    > "$proj/.baton/terminals/${th}.json"
  jq -n --arg ws "$ws" '{workstream:$ws, display_name:$ws, progress_file:"",
    phase:"implementation", updated_at:"2026-07-18T00:00:00Z"}' \
    > "$proj/.baton/workstreams/${ws}.json"
}

run_wt() {
  local proj="$1" sid="$2" term="$3" file="$4"
  jq -n --arg sid "$sid" --arg cwd "$proj" --arg f "$file" \
    '{session_id:$sid, cwd:$cwd, tool_name:"Write", tool_input:{file_path:$f}}' | \
    USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    XDG_CONFIG_HOME="$proj/.config" \
    BATON_DIR="$proj/.baton" BATON_ARCHIVE_DIR="$proj/archive" \
    bash "$WT" 2>/dev/null
}

# B1: wrong workstream in the basename, WITH a workstream successfully bound.
# The second assertion is load-bearing: B1 and B2 both emit decision=block from
# the same basename-reject block, so `.decision == "block"` alone cannot tell
# them apart. If the terminal bind ever breaks again, B1 silently degrades onto
# B2's no-workstream payload and stops testing this path at all. This string is
# emitted ONLY when a workstream was resolved and did not match the basename.
proj=$(mkproj); sid="wt-b1-$$"; term="term-b1-$$"
bind_ws "$proj" "realws" "$term"
touch "/tmp/baton-pending-${sid}"
f="$proj/.baton/progress/progress-otherws-deadbee.md"
printf 'x\n' > "$f"
b1_out=$(run_wt "$proj" "$sid" "$term" "$f")
assert_blocks "B1: basename-reject blocks" "$b1_out"
if printf '%s' "$b1_out" | grep -q 'does not belong to the current workstream'; then
  _ok "B1b: rejected WITH a bound workstream (not the no-workstream path)"
else
  _bad "B1b: rejected WITH a bound workstream (not the no-workstream path)"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

# B2: no workstream resolvable at all. Discriminated by the event record, which
# carries the empty workstream; the payload text is the other half of the pair
# asserted in B1b.
proj=$(mkproj); sid="wt-b2-$$"; term="term-b2-$$"
touch "/tmp/baton-pending-${sid}"
f="$proj/.baton/progress/progress-anything-deadbee.md"
printf 'x\n' > "$f"
assert_blocks "B2: unresolvable workstream blocks" "$(run_wt "$proj" "$sid" "$term" "$f")"
if grep -q '"event":"basename-reject".*"workstream":""' "$proj/.baton/hook-events.jsonl" 2>/dev/null; then
  _ok "B2b: recorded as a basename-reject with no workstream"
else
  _bad "B2b: recorded as a basename-reject with no workstream"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

# B3: pointer write fails (workstreams dir made read-only).
# The fixture MUST be a lint-clean progress file. The lint pipeline (V8 then V1)
# runs BEFORE the pointer write, so an unrendered template dies at V8 on its
# surviving <<...>> tokens and a bare 'x' dies at V1 on the missing Session
# Directive - either way execution never reaches SAVE_OK=false and B3 passes
# vacuously on the lint's own block payload while appearing to test the pointer
# write. Render the active template instead: substitute the model-authored
# tokens and copy the directive forward verbatim (which the copy does for free).
# No fallback branch - if the template cannot be read this must fail loudly
# rather than silently retarget onto the lint path.
proj=$(mkproj); sid="wt-b3-$$"; term="term-b3-$$"
bind_ws "$proj" "realws" "$term"
touch "/tmp/baton-pending-${sid}"
f="$proj/.baton/progress/progress-realws-deadbee.md"
sed -e 's/<<CONSTRAINTS_BLOCKERS>>/None/' \
    -e 's|<<WHATS_NEXT>>|- Open .claude/hooks/checkpoint-write-trigger.sh:249 and verify the block payload.|' \
    "$TPL" > "$f"
if sed '/<!--/,/-->/d' "$f" | grep -qE '<<[A-Z_]+>>'; then
  _bad "B3 fixture: unfilled tokens survive - fixture would die at V8, not the pointer write"
fi
chmod a-w "$proj/.baton/workstreams"
out=$(run_wt "$proj" "$sid" "$term" "$f")
chmod u+w "$proj/.baton/workstreams"
assert_blocks "B3: pointer-write failure blocks" "$out"
if [ -f "/tmp/baton-done-${sid}" ]; then
  _bad "B4: pointer-write failure must NOT latch DONE"
else
  _ok "B4: pointer-write failure must NOT latch DONE"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

# B5: static sweep - no terminal failure path may emit the stripped shape.
if grep -n 'CHECKPOINT WARNING' "$WT" >/dev/null 2>&1; then
  _bad "B5: no advisory-only failure payload remains"
else
  _ok "B5: no advisory-only failure payload remains"
fi

# B6: writing the scaffold must not register it as the handoff.
# PRECONDITION: PENDING planted and DONE absent - see the two notes above. The
# fixture is the rendered template, NOT a bare 'x': a bare 'x' dies at the V1
# lint before the pointer save, and every assertion here then passes on an
# unfixed tree.
proj=$(mkproj); sid="wt-b6-$$"; term="term-b6-$$"
bind_ws "$proj" "realws" "$term"
touch "/tmp/baton-pending-${sid}"
f="$proj/.baton/progress/progress-realws-deadbee.scaffold.md"
sed -e 's/<<CONSTRAINTS_BLOCKERS>>/None/' \
    -e 's|<<WHATS_NEXT>>|- Open .claude/hooks/checkpoint-write-trigger.sh:72 and check the basename case.|' \
    "$TPL" > "$f"
if sed '/<!--/,/-->/d' "$f" | grep -qE '<<[A-Z_]+>>'; then
  _bad "B6 fixture: template still has unrendered tokens - B6 would test the lint, not the guard"
fi
b6_out=$(run_wt "$proj" "$sid" "$term" "$f")
if [ -f "/tmp/baton-done-${sid}" ]; then
  _bad "B6: scaffold write must not latch DONE"
else
  _ok "B6: scaffold write must not latch DONE"
fi
if [ "$(jq -r '.progress_file' "$proj/.baton/workstreams/realws.json")" = "" ]; then
  _ok "B6b: scaffold write must not become the registered handoff"
else
  _bad "B6b: scaffold write must not become the registered handoff"
fi
# B6c: the scaffold arm exits before any payload, so a correct hook says nothing
# at all here. This is the assertion that stays red on an unfixed tree even if
# the fixture is ever downgraded back to a bare 'x'.
if [ -z "$b6_out" ]; then
  _ok "B6c: scaffold write emits no payload"
else
  _bad "B6c: scaffold write emits no payload (got: $(printf '%s' "$b6_out" | head -c 120))"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

# B7: with no pre-existing workstream record, the display name must not blank.
# A blank display_name empties the roster entry and permanently disables the
# display-name arm of the basename guard, so every later write on this
# workstream is judged on the id alone.
proj=$(mkproj); sid="wt-b7-$$"; term="term-b7-$$"
th=$(USER=u CLAUDE_TERMINAL_ID="$term" bash -c "source $HOOKS_DIR/lib/workstream-lib.sh; term_hash")
jq -n '{terminal_id:"t", workstream:"realws", updated_at:"2026-07-18T00:00:00Z"}' \
  > "$proj/.baton/terminals/${th}.json"
# deliberately NO workstreams/realws.json - this is the record-absent branch
touch "/tmp/baton-pending-${sid}"
f="$proj/.baton/progress/progress-realws-deadbee.md"
sed -e 's/<<CONSTRAINTS_BLOCKERS>>/None/' \
    -e 's|<<WHATS_NEXT>>|- Open .claude/hooks/checkpoint-write-trigger.sh:202 and check the display name.|' \
    "$TPL" > "$f"
b7_out=$(run_wt "$proj" "$sid" "$term" "$f")
dn=$(jq -r '.display_name // ""' "$proj/.baton/workstreams/realws.json" 2>/dev/null)
if [ -n "$dn" ]; then
  _ok "B7: record-absent branch writes a non-empty display_name (got '$dn')"
else
  _bad "B7: record-absent branch writes a non-empty display_name (got empty)"
fi
# C2: this case plants NO /tmp/claude-context-pct-<sid>, which is exactly the
# condition step 7's empty-percentage guard exists for, and it drives a full
# success path - so the success payload is free evidence and was previously
# thrown away with a >/dev/null. Without these two lines C2 has no test and no
# behavioural assertion anywhere in the plan; task 6 step 4 would attest it
# against a grep alone. Do NOT plant a pct file in this case to make some other
# assertion tidier - its absence IS the fixture.
if printf '%s' "$b7_out" | grep -q 'Progress saved.'; then
  _ok "C2: success message with no pct file still tells the user progress saved"
else
  _bad "C2: success message with no pct file still tells the user progress saved (got: $(printf '%s' "$b7_out" | head -c 200))"
fi
if printf '%s' "$b7_out" | grep -q 'Context at '; then
  _bad "C2b: no percentage clause when the pct file is absent (got: $(printf '%s' "$b7_out" | head -c 200))"
else
  _ok "C2b: no percentage clause when the pct file is absent"
fi
rm -f "/tmp/baton-pending-${sid}" "/tmp/baton-done-${sid}"

echo; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
