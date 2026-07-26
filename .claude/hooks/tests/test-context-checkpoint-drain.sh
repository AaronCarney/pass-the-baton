#!/usr/bin/env bash
# Drain-gate + consent-escape + subagent-block tests for context-checkpoint.sh.
#
# Output-capture vars are consumed inside ok()'s eval'd assertion string and via
# has()'s ${!1} indirection. shellcheck cannot trace either, so every one of them
# reads as unused. File-level because the idiom is structural, not incidental.
# shellcheck disable=SC2034
set -u
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
CC="$HOOKS/context-checkpoint.sh"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
has(){ printf '%s' "${!1}" | grep -q "$2"; }   # $1 = NAME of the var holding output

export CLAUDE_TERMINAL_ID="unit-drain-tty"
TH=$(printf '%s' "${USER}:${CLAUDE_TERMINAL_ID}" | md5sum | cut -d' ' -f1)
SID="unit-drain-sess"
PROJ=$(mktemp -d); export CLAUDE_PROJECT_DIR="$PROJ"
export BATON_DIR="$PROJ/.baton"; mkdir -p "$BATON_DIR"
cleanup(){ rm -rf "$PROJ" "/tmp/baton-subagents-active-${SID}"; \
  rm -f "/tmp/claude-context-pct-${SID}" "/tmp/claude-context-triggered-${SID}" \
    "/tmp/baton-pending-${SID}" "/tmp/baton-done-${SID}" "/tmp/baton-nag-${SID}" \
    "/tmp/baton-unlock-${SID}" "/tmp/baton-snooze-${SID}" "/tmp/baton-manual-${SID}" \
    "/tmp/baton-archive-${SID}" "/tmp/claude-subagent-checkpoint-subZ" \
    "/tmp/claude-parent-sid-${TH}"; }
trap cleanup EXIT; cleanup
echo "$SID" > "/tmp/claude-parent-sid-${TH}"
source "$HOOKS/lib/drain-gate.sh"

run(){ printf '%s' "$1" | bash "$CC" 2>/dev/null; }
mk(){ printf '{"session_id":"%s","cwd":"%s","tool_name":"%s"%s}' "$SID" "$PROJ" "$1" "$2"; }

# --- Arm an owed checkpoint above threshold ---
printf '95' > "/tmp/claude-context-pct-${SID}"
out=$(run "$(mk Bash '')")                      # first fire arms FLAG + PENDING
ok "first fire arms + allows" "has out 'CHECKPOINT TRIGGERED' && [ -f /tmp/baton-pending-${SID} ]"

# --- Drain gate: subagent in flight holds the write ---
drain::mark_start "$SID" agentX
WRITE_PAYLOAD='{"session_id":"'$SID'","cwd":"'$PROJ'","tool_name":"Write","tool_input":{"file_path":"'$BATON_DIR'/progress/progress-'$SID'.md"}}'
out=$(printf '%s' "$WRITE_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "progress write DENIED while draining" "has out 'deny' && has out 'subagent'"
ok "drain-HOLD ships the toolpolicy announce" "has out 'keep orienting'"
# read-only stays allowed during drain (no deny)
READ_PAYLOAD='{"session_id":"'$SID'","cwd":"'$PROJ'","tool_name":"Read","tool_input":{"file_path":"'$PROJ'/x"}}'
out=$(printf '%s' "$READ_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "read allowed during drain" "! has out '\"deny\"'"

# --- Drain clears: progress write no longer denied by drain ---
drain::mark_stop "$SID" agentX
out=$(printf '%s' "$WRITE_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "progress write not drain-denied when clear" "! ( has out 'deny' && has out 'subagent' )"

# --- Hung drain (F3a): active marker + timeout 0 -> native ask force-past ---
drain::mark_start "$SID" agentH
BASH_PAYLOAD='{"session_id":"'$SID'","cwd":"'$PROJ'","tool_name":"Bash"}'
out=$(printf '%s' "$BASH_PAYLOAD" | BATON_DRAIN_TIMEOUT_SECS=0 bash "$CC" 2>/dev/null)
ok "hung drain asks (force-past)" "has out '\"ask\"'"
ok "hung drain does not deny" "! has out '\"deny\"'"
ok "hung-drain prompt does not claim the subagents produced nothing" "has out 'They may still be working'"
drain::mark_stop "$SID" agentH

# --- Manual marker no longer asks pre-write (E2): consent is a POST-write question ---
touch "/tmp/baton-manual-${SID}"
out=$(printf '%s' "$BASH_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "manual marker does not ask pre-write (clear drain)" "! has out '\"ask\"'"
ok "manual marker nudges instead" "has out 'CHECKPOINT STILL PENDING'"

# --- Manual exempt (F3c): manual marker + progress-write is NOT asked (falls through to save) ---
out=$(printf '%s' "$WRITE_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "manual progress-write is exempt (no ask)" "! has out '\"ask\"'"

# --- No manual marker (F3d): consequential on the clear owed path does NOT ask ---
rm -f "/tmp/baton-manual-${SID}"
out=$(printf '%s' "$BASH_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "no manual marker: consequential does not ask" "! has out '\"ask\"'"

# --- Force-consume producer contract (F3e): consuming the force flag drops the manual marker ---
SIDF="unit-drain-force-$$"
printf '95' > "/tmp/claude-context-pct-${SIDF}"
touch "/tmp/baton-force-checkpoint-${SIDF}"; rm -f "/tmp/baton-manual-${SIDF}"
FORCE_PAYLOAD='{"session_id":"'$SIDF'","cwd":"'$PROJ'","tool_name":"Bash"}'
printf '%s' "$FORCE_PAYLOAD" | bash "$CC" >/dev/null 2>&1
ok "force consume creates the manual marker" "[ -f /tmp/baton-manual-${SIDF} ]"
rm -f "/tmp/baton-force-checkpoint-${SIDF}" "/tmp/baton-manual-${SIDF}" "/tmp/claude-context-pct-${SIDF}" \
  "/tmp/baton-pending-${SIDF}" "/tmp/baton-done-${SIDF}" "/tmp/claude-context-triggered-${SIDF}" \
  "/tmp/baton-archive-${SIDF}"

# --- Full unlock: /off no-ops the lifecycle ---
touch "/tmp/baton-unlock-${SID}"
out=$(printf '%s' "$WRITE_PAYLOAD" | bash "$CC" 2>/dev/null)
ok "unlock no-ops (no output)" "[ -z \"$out\" ]"
rm -f "/tmp/baton-unlock-${SID}"

# --- Snooze: unexpired defers, expired is cleared ---
printf '%s' "$(( $(date +%s) + 600 ))" > "/tmp/baton-snooze-${SID}"
# fresh session id so no owed FLAG interferes
SID2="unit-drain-sess2"; printf '95' > "/tmp/claude-context-pct-${SID2}"
printf '%s' "$(( $(date +%s) + 600 ))" > "/tmp/baton-snooze-${SID2}"
P2='{"session_id":"'$SID2'","cwd":"'$PROJ'","tool_name":"Bash"}'
out=$(printf '%s' "$P2" | bash "$CC" 2>/dev/null)
ok "snooze suppresses trigger" "! has out 'CHECKPOINT TRIGGERED' && [ ! -f /tmp/baton-pending-${SID2} ]"
printf '%s' "$(( $(date +%s) - 5 ))" > "/tmp/baton-snooze-${SID2}"
out=$(printf '%s' "$P2" | bash "$CC" 2>/dev/null)
ok "expired snooze removed" "[ ! -f /tmp/baton-snooze-${SID2} ]"
ok "expired snooze re-arms the checkpoint" "has out 'CHECKPOINT TRIGGERED' && [ -f /tmp/baton-pending-${SID2} ]"
rm -f "/tmp/claude-context-pct-${SID2}" "/tmp/baton-pending-${SID2}" "/tmp/baton-done-${SID2}" \
  "/tmp/claude-context-triggered-${SID2}" "/tmp/baton-nag-${SID2}" "/tmp/baton-archive-${SID2}"

# --- Subagent block: allowed, never denied post-DONE ---
touch "/tmp/baton-done-${SID}"
SUB='{"session_id":"subZ","cwd":"'$PROJ'","tool_name":"Bash","agent_id":"agentZ"}'
rm -f "/tmp/claude-subagent-checkpoint-subZ"
out=$(printf '%s' "$SUB" | bash "$CC" 2>/dev/null)
ok "subagent NOT denied after parent DONE" "! has out '\"deny\"'"
ok "subagent gets the wrap-up nudge" "has out 'return your results to the parent'"
rm -f "/tmp/baton-done-${SID}" "/tmp/claude-subagent-checkpoint-subZ"

# --- Subagent one-shot dedupe (G4a): nudge fires once, suppressed on the 2nd call ---
SUBD='{"session_id":"subDedup","cwd":"'$PROJ'","tool_name":"Bash","agent_id":"agentD"}'
rm -f "/tmp/claude-subagent-checkpoint-subDedup"
out=$(printf '%s' "$SUBD" | bash "$CC" 2>/dev/null)
ok "subagent nudge fires on first call" "has out 'return your results to the parent'"
out=$(printf '%s' "$SUBD" | bash "$CC" 2>/dev/null)
ok "subagent nudge suppressed on second call" "[ -z \"$out\" ]"
rm -f "/tmp/claude-subagent-checkpoint-subDedup"

# --- Subagent below threshold (G4b): parent PCT < CC_THRESHOLD -> no nudge ---
printf '5' > "/tmp/claude-context-pct-${SID}"
SUBL='{"session_id":"subLow","cwd":"'$PROJ'","tool_name":"Bash","agent_id":"agentL"}'
rm -f "/tmp/claude-subagent-checkpoint-subLow"
out=$(printf '%s' "$SUBL" | bash "$CC" 2>/dev/null)
ok "subagent below threshold emits no nudge" "[ -z \"$out\" ]"
printf '95' > "/tmp/claude-context-pct-${SID}"
rm -f "/tmp/claude-subagent-checkpoint-subLow"

# --- Drain-gate-unavailable (G1): broken install (drain-gate.sh missing) -> fail-LOUD deny ---
# Copy the hook tree and remove the correctness-core lib so `source` fails and drain::is_clear
# is undefined; SCRIPT_DIR resolves via $0 (context-checkpoint.sh:16) to the copy, so the real
# tree is untouched. A missing lib must DENY the write - never silently pass as "drain clear".
HK=$(mktemp -d); cp -r "$HOOKS" "$HK/hooks"; rm -f "$HK/hooks/lib/drain-gate.sh"
SIDU="unit-drain-unavail-$$"
printf '95' > "/tmp/claude-context-pct-${SIDU}"
UP='{"session_id":"'$SIDU'","cwd":"'$PROJ'","tool_name":"Bash"}'
printf '%s' "$UP" | bash "$HK/hooks/context-checkpoint.sh" >/dev/null 2>&1   # first fire arms owed state
out=$(printf '%s' "$UP" | bash "$HK/hooks/context-checkpoint.sh" 2>/dev/null)  # owed block -> drain gate unavailable
ok "drain-gate-unavailable denies the write" "has out '\"deny\"'"
ok "drain-gate-unavailable names the repair" "has out 'drain gate is unavailable' || has out 'Repair the install'"
ok "drain-gate-unavailable does not increment the nag" "[ ! -f /tmp/baton-nag-${SIDU} ]"
rm -rf "$HK"; rm -f "/tmp/claude-context-pct-${SIDU}" "/tmp/baton-pending-${SIDU}" \
  "/tmp/baton-done-${SIDU}" "/tmp/claude-context-triggered-${SIDU}" "/tmp/baton-nag-${SIDU}" \
  "/tmp/baton-archive-${SIDU}"

# --- Tool-policy-unavailable (C3): drain-gate present but tool-policy.sh missing ---
# Symmetric sibling of G1. With a subagent in flight and tool-policy.sh unloadable, the
# owed block cannot classify tools, so it degrades read-only to GATED (fail-safe) and logs
# a `tool-policy-unavailable` trace. A read-only Read is held (denied) AND leaves that trace
# in the events log ($BATON_DIR/hook-events.jsonl via log_event).
HKT=$(mktemp -d); cp -r "$HOOKS" "$HKT/hooks"; rm -f "$HKT/hooks/lib/tool-policy.sh"
SIDT="unit-drain-tpunavail-$$"
printf '95' > "/tmp/claude-context-pct-${SIDT}"
drain::mark_start "$SIDT" agentTP        # subagent in flight -> drain not clear
ARMT='{"session_id":"'$SIDT'","cwd":"'$PROJ'","tool_name":"Bash"}'
printf '%s' "$ARMT" | bash "$HKT/hooks/context-checkpoint.sh" >/dev/null 2>&1   # arms owed state
TPP='{"session_id":"'$SIDT'","cwd":"'$PROJ'","tool_name":"Read"}'
out=$(printf '%s' "$TPP" | bash "$HKT/hooks/context-checkpoint.sh" 2>/dev/null)  # owed + tool-policy missing
ok "tool-policy-unavailable gates the read-only tool" "has out '\"deny\"'"
ok "tool-policy-unavailable deny names the missing tool policy" "has out 'tool policy is unavailable'"
ok "tool-policy-unavailable trace is logged" "grep -q tool-policy-unavailable \"$BATON_DIR/hook-events.jsonl\" 2>/dev/null"
ok "tool-policy-unavailable does not increment the nag" "[ ! -f /tmp/baton-nag-${SIDT} ]"
# Escape survives (Step 7b guard): tool-policy missing AND drain hung past timeout
# must still force-past ask, never hard-deny every tool with no way out.
outTPH=$(printf '%s' "$TPP" | BATON_DRAIN_TIMEOUT_SECS=0 bash "$HKT/hooks/context-checkpoint.sh" 2>/dev/null)
ok "tool-policy-unavailable still force-past asks when drain is hung" "printf '%s' \"\$outTPH\" | grep -q '\"ask\"' && ! printf '%s' \"\$outTPH\" | grep -q '\"deny\"'"
drain::mark_stop "$SIDT" agentTP
rm -rf "$HKT" "/tmp/baton-subagents-active-${SIDT}"; rm -f "/tmp/claude-context-pct-${SIDT}" \
  "/tmp/baton-pending-${SIDT}" "/tmp/baton-done-${SIDT}" "/tmp/claude-context-triggered-${SIDT}" \
  "/tmp/baton-nag-${SIDT}" "/tmp/baton-archive-${SIDT}"

# --- Manual path nudges, creates no counter, and logs pending-manual ---
SIDM="unit-drain-manualnag-$$"
rm -f "/tmp/baton-nag-${SIDM}" "/tmp/baton-manual-${SIDM}" "/tmp/baton-pending-${SIDM}" \
  "/tmp/claude-context-triggered-${SIDM}" "/tmp/claude-context-pct-${SIDM}"
printf '95' > "/tmp/claude-context-pct-${SIDM}"
touch "/tmp/claude-context-triggered-${SIDM}"
: > "/tmp/baton-pending-${SIDM}"
touch "/tmp/baton-manual-${SIDM}"
outM=$(printf '%s' '{"session_id":"'"$SIDM"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path never creates the nag counter" "[ ! -f /tmp/baton-nag-${SIDM} ]"
ok "manual path emits the pending nudge" "printf '%s' \"\$outM\" | grep -q 'CHECKPOINT STILL PENDING'"
# Match on BOTH the event name and the session id so a record from another case
# cannot satisfy it. $BATON_DIR is exported at the top of this file; log_event
# writes to $BATON_DIR/hook-events.jsonl.
ok "manual path logs pending-manual for this session" "grep pending-manual \"$BATON_DIR/hook-events.jsonl\" 2>/dev/null | grep -q ${SIDM}"
rm -f "/tmp/baton-nag-${SIDM}" "/tmp/baton-manual-${SIDM}" "/tmp/baton-pending-${SIDM}" \
  "/tmp/claude-context-triggered-${SIDM}" "/tmp/claude-context-pct-${SIDM}"

# --- Manual path never denies, whatever a stale counter says ---
# The seeded /tmp/baton-nag values below are stale state from an older session.
# Task 1 removed the escalation, so none of them can make the manual path deny;
# they stay in the fixture as evidence that a leftover counter is inert.
SIDL="unit-drain-manuallimit-$$"
rm -f "/tmp/baton-nag-${SIDL}" "/tmp/baton-manual-${SIDL}" "/tmp/baton-pending-${SIDL}" \
  "/tmp/claude-context-triggered-${SIDL}" "/tmp/claude-context-pct-${SIDL}"
printf '95' > "/tmp/claude-context-pct-${SIDL}"
touch "/tmp/claude-context-triggered-${SIDL}"
: > "/tmp/baton-pending-${SIDL}"
touch "/tmp/baton-manual-${SIDL}"
echo 5 > "/tmp/baton-nag-${SIDL}"          # a stale counter from an older session; must be ignored
outL=$(printf '%s' '{"session_id":"'"$SIDL"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path does not deny however high the stale counter" "! printf '%s' \"\$outL\" | grep -q '\"deny\"'"
# Task 1 removed the manual escalation entirely. The assertions here pin its
# absence: the path emits the STILL PENDING nudge, never the old hard-deny menu
# ('after repeated prompts') and never its pass-the-baton:off escape, whatever
# the stale counter holds.
ok "manual path emits the pending nudge instead of a deny" "printf '%s' \"\$outL\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "manual path emits no 'after repeated prompts' menu" "! printf '%s' \"\$outL\" | grep -q 'after repeated prompts'"
ok "manual path offers no pass-the-baton:off escape menu" "! printf '%s' \"\$outL\" | grep -q 'pass-the-baton:off'"
echo 0 > "/tmp/baton-nag-${SIDL}"          # a different stale value; still just the nudge
outB=$(printf '%s' '{"session_id":"'"$SIDL"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path nudges at a low stale counter" "printf '%s' \"\$outB\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "manual path does not ask at a low stale counter" "! printf '%s' \"\$outB\" | grep -q '\"ask\"'"
echo 2 > "/tmp/baton-nag-${SIDL}"          # yet another stale value the manual path must ignore
outBd=$(printf '%s' '{"session_id":"'"$SIDL"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path does not deny at any stale counter value" "! printf '%s' \"\$outBd\" | grep -q '\"deny\"'"
echo 1 > "/tmp/baton-nag-${SIDL}"          # and one more; the counter is never read or advanced now
outBa=$(printf '%s' '{"session_id":"'"$SIDL"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path still nudges at another stale counter value" "printf '%s' \"\$outBa\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "manual path still does not ask at that value" "! printf '%s' \"\$outBa\" | grep -q '\"ask\"'"
rm -f "/tmp/baton-nag-${SIDL}" "/tmp/baton-manual-${SIDL}" "/tmp/baton-pending-${SIDL}" \
  "/tmp/claude-context-triggered-${SIDL}" "/tmp/claude-context-pct-${SIDL}"

# --- Manual path denies neither read-only nor gate tools, counter untouched ---
# Read-only orientation tools must never be denied and must never advance the
# counter on the manual path. Every other manual case here drives Bash; this one
# drives Grep, and the Bash arm below confirms a gate tool is no longer denied
# either - task 1 removed the deny for both classes.
SIDR="unit-drain-manualro-$$"
rm -f "/tmp/baton-nag-${SIDR}" "/tmp/baton-manual-${SIDR}" "/tmp/baton-pending-${SIDR}" \
  "/tmp/claude-context-triggered-${SIDR}" "/tmp/claude-context-pct-${SIDR}"
printf '95' > "/tmp/claude-context-pct-${SIDR}"
touch "/tmp/claude-context-triggered-${SIDR}"
: > "/tmp/baton-pending-${SIDR}"
touch "/tmp/baton-manual-${SIDR}"
echo 5 > "/tmp/baton-nag-${SIDR}"          # a stale counter; must stay untouched
outRO=$(printf '%s' '{"session_id":"'"$SIDR"'","cwd":"'"$PROJ"'","tool_name":"Grep"}' | bash "$CC" 2>/dev/null)
ok "manual path does not deny a read-only tool" "! printf '%s' \"\$outRO\" | grep -q '\"deny\"'"
ok "manual path read-only leaves the stale counter untouched" "[ \"\$(cat /tmp/baton-nag-${SIDR} 2>/dev/null)\" = 5 ]"
outROg=$(printf '%s' '{"session_id":"'"$SIDR"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "manual path does not deny a gate tool either at the same state" "! printf '%s' \"\$outROg\" | grep -q '\"deny\"'"
rm -f "/tmp/baton-nag-${SIDR}" "/tmp/baton-manual-${SIDR}" "/tmp/baton-pending-${SIDR}" \
  "/tmp/claude-context-triggered-${SIDR}" "/tmp/claude-context-pct-${SIDR}"

# --- Manual path leaves no counter behind on the progress-file write ---
# The progress-*.md Write is the one write that clears PENDING. Task 1 removed
# the counter entirely, so no baton-nag file is created on this path either -
# this case pins that the progress write in particular leaves none behind.
SIDE2="unit-drain-manualexempt-$$"
rm -f "/tmp/baton-nag-${SIDE2}" "/tmp/baton-manual-${SIDE2}" "/tmp/baton-pending-${SIDE2}" \
  "/tmp/claude-context-triggered-${SIDE2}" "/tmp/claude-context-pct-${SIDE2}"
printf '95' > "/tmp/claude-context-pct-${SIDE2}"
touch "/tmp/claude-context-triggered-${SIDE2}"
: > "/tmp/baton-pending-${SIDE2}"
touch "/tmp/baton-manual-${SIDE2}"
printf '%s' '{"session_id":"'"$SIDE2"'","cwd":"'"$PROJ"'","tool_name":"Write","tool_input":{"file_path":"progress-'"$SIDE2"'.md"}}' | bash "$CC" >/dev/null 2>&1
ok "manual path leaves no counter on the progress-file write" "[ ! -f /tmp/baton-nag-${SIDE2} ]"
rm -f "/tmp/baton-nag-${SIDE2}" "/tmp/baton-manual-${SIDE2}" "/tmp/baton-pending-${SIDE2}" \
  "/tmp/claude-context-triggered-${SIDE2}" "/tmp/claude-context-pct-${SIDE2}"

# --- Drain-held write does not touch the nag counter (control, guards ordering) ---
# While a subagent is in flight the drain gate denies+exits at the TOP of the hook
# (context-checkpoint.sh:244-277), ABOVE the nag block. The existing drain-hold
# fixture (~lines 33-37) proves the progress Write is denied while draining but
# never checks baton-nag. This control pins that ordering: a future mis-hoist of
# the nag code above the drain gate would hard-deny mid-drain (defeating the gate)
# yet keep every suite green. BATON_DIR is exported at the top of this file.
SIDDR="unit-drain-heldnag-$$"
rm -f "/tmp/baton-nag-${SIDDR}" "/tmp/baton-pending-${SIDDR}" \
  "/tmp/claude-context-triggered-${SIDDR}" "/tmp/claude-context-pct-${SIDDR}"
printf '95' > "/tmp/claude-context-pct-${SIDDR}"
touch "/tmp/claude-context-triggered-${SIDDR}"
: > "/tmp/baton-pending-${SIDDR}"
drain::mark_start "$SIDDR" agentHeld
outDR=$(printf '%s' '{"session_id":"'"$SIDDR"'","cwd":"'"$PROJ"'","tool_name":"Write","tool_input":{"file_path":"'"$BATON_DIR"'/progress/progress-'"$SIDDR"'.md"}}' | bash "$CC" 2>/dev/null)
ok "drain-held write is denied by the drain gate" "printf '%s' \"\$outDR\" | grep -q 'deny' && printf '%s' \"\$outDR\" | grep -q 'subagent'"
ok "drain-held write does not increment the nag" "[ ! -f /tmp/baton-nag-${SIDDR} ]"
drain::mark_stop "$SIDDR" agentHeld
rm -f "/tmp/baton-nag-${SIDDR}" "/tmp/baton-pending-${SIDDR}" \
  "/tmp/claude-context-triggered-${SIDDR}" "/tmp/claude-context-pct-${SIDDR}"

# --- Automated path does NOT hard-deny, even with a stale counter present -----
# Pre-E1 this block asserted the opposite: the generic deny was the automated
# path's escalation. E1 removed that escalation, so the assertions invert. A
# stale /tmp/baton-nag file left by an earlier manual arming must not resurrect
# the deny once the manual marker is gone.
SIDG="unit-drain-genericlimit-$$"
rm -f "/tmp/baton-nag-${SIDG}" "/tmp/baton-manual-${SIDG}" "/tmp/baton-pending-${SIDG}" \
  "/tmp/claude-context-triggered-${SIDG}" "/tmp/claude-context-pct-${SIDG}"
printf '95' > "/tmp/claude-context-pct-${SIDG}"
touch "/tmp/claude-context-triggered-${SIDG}"
: > "/tmp/baton-pending-${SIDG}"
# deliberately NO baton-manual marker
echo 5 > "/tmp/baton-nag-${SIDG}"          # a stale counter left by an older session
outG=$(printf '%s' '{"session_id":"'"$SIDG"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "automated path does not deny despite a stale past-limit counter" "! printf '%s' \"\$outG\" | grep -q '\"deny\"'"
ok "automated path emits the write instruction instead" "printf '%s' \"\$outG\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "automated path does not advance the stale counter" "[ \"\$(cat /tmp/baton-nag-${SIDG} 2>/dev/null)\" = 5 ]"
rm -f "/tmp/baton-nag-${SIDG}" "/tmp/baton-manual-${SIDG}" "/tmp/baton-pending-${SIDG}" \
  "/tmp/claude-context-triggered-${SIDG}" "/tmp/claude-context-pct-${SIDG}"

# --- AUTOMATED path carries no nag (E1) -------------------------------------
# No baton-manual marker == threshold-fired == nobody in the loop. The hook must
# emit the write instruction and nothing else: no counter file, no
# pending-unsatisfied event, and no deny however many times it is called.
SIDA="unit-drain-autonag-$$"
rm -f "/tmp/baton-nag-${SIDA}" "/tmp/baton-manual-${SIDA}" "/tmp/baton-pending-${SIDA}" \
  "/tmp/claude-context-triggered-${SIDA}" "/tmp/claude-context-pct-${SIDA}"
printf '95' > "/tmp/claude-context-pct-${SIDA}"
touch "/tmp/claude-context-triggered-${SIDA}"
: > "/tmp/baton-pending-${SIDA}"
# deliberately NO baton-manual marker
outA=$(printf '%s' '{"session_id":"'"$SIDA"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
ok "automated path never creates the nag counter" "[ ! -f /tmp/baton-nag-${SIDA} ]"
ok "automated path does not deny" "! printf '%s' \"\$outA\" | grep -q '\"deny\"'"
ok "automated path does not ask" "! printf '%s' \"\$outA\" | grep -q '\"ask\"'"
ok "automated path still emits the write instruction" "printf '%s' \"\$outA\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "automated path logs no pending-unsatisfied for this session" "! grep pending-unsatisfied \"$BATON_DIR/hook-events.jsonl\" 2>/dev/null | grep -q ${SIDA}"
ok "automated path logs pending-automated for this session" "grep pending-automated \"$BATON_DIR/hook-events.jsonl\" 2>/dev/null | grep -q ${SIDA}"

# Past the OLD limit: ten consecutive calls must still never escalate.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  outA10=$(printf '%s' '{"session_id":"'"$SIDA"'","cwd":"'"$PROJ"'","tool_name":"Bash"}' | bash "$CC" 2>/dev/null)
done
ok "automated path still no counter after 10 calls" "[ ! -f /tmp/baton-nag-${SIDA} ]"
ok "automated path still does not deny after 10 calls" "! printf '%s' \"\$outA10\" | grep -q '\"deny\"'"
rm -f "/tmp/baton-nag-${SIDA}" "/tmp/baton-manual-${SIDA}" "/tmp/baton-pending-${SIDA}" \
  "/tmp/claude-context-triggered-${SIDA}" "/tmp/claude-context-pct-${SIDA}"

# --- Scaffold lands even when the progress dir does not exist yet ---
SIDS="unit-drain-scaffold-$$"
PROJS=$(mktemp -d)
rm -f "/tmp/claude-context-pct-${SIDS}" "/tmp/claude-context-triggered-${SIDS}" \
  "/tmp/baton-pending-${SIDS}" "/tmp/baton-nag-${SIDS}"
printf '95' > "/tmp/claude-context-pct-${SIDS}"
CLAUDE_PROJECT_DIR="$PROJS" BATON_DIR="$PROJS/.baton" bash "$CC" \
  <<<"{\"session_id\":\"$SIDS\",\"cwd\":\"$PROJS\",\"tool_name\":\"Bash\"}" >/dev/null 2>&1
ok "scaffold is written into a not-yet-existing progress dir" \
  "[ -n \"\$(find '$PROJS' -name '*.scaffold.md' -type f 2>/dev/null)\" ]"
rm -rf "$PROJS"
rm -f "/tmp/claude-context-pct-${SIDS}" "/tmp/claude-context-triggered-${SIDS}" \
  "/tmp/baton-pending-${SIDS}" "/tmp/baton-nag-${SIDS}"

# E3-DEADLOCK: nothing the checkpoint workflow might need is gated before the write.
# The old exemption list enumerated three cases (progress-*.md writes, scaffold reads,
# active-template reads). The deadlock class was everything it did NOT enumerate. These
# calls are all unenumerated, on the MANUAL path, with a stale counter far past the
# retired limit - the exact state that used to hard-deny.
SIDDL="unit-drain-e3deadlock-$$"
rm -f "/tmp/baton-nag-${SIDDL}" "/tmp/baton-manual-${SIDDL}" "/tmp/baton-pending-${SIDDL}" \
  "/tmp/claude-context-triggered-${SIDDL}" "/tmp/claude-context-pct-${SIDDL}"
printf '95' > "/tmp/claude-context-pct-${SIDDL}"
touch "/tmp/claude-context-triggered-${SIDDL}"
: > "/tmp/baton-pending-${SIDDL}"
touch "/tmp/baton-manual-${SIDDL}"
echo 99 > "/tmp/baton-nag-${SIDDL}"   # far past the retired limit
blockedDL=""
for specDL in "Read:$PROJ/some-unenumerated-note.md" \
              "Grep:$PROJ/x" \
              "Bash:" \
              "Write:$PROJ/not-a-progress-file.md" \
              "Edit:$PROJ/lib/helper.sh" \
              "Read:$PROJ/docs/handoff-template.md"; do
  toolDL="${specDL%%:*}"; fpDL="${specDL#*:}"
  outDL=$(printf '%s' '{"session_id":"'"$SIDDL"'","cwd":"'"$PROJ"'","tool_name":"'"$toolDL"'","tool_input":{"file_path":"'"$fpDL"'"}}' \
    | bash "$CC" 2>/dev/null)
  printf '%s' "$outDL" | grep -q '"deny"' && blockedDL="$blockedDL $toolDL"
done
ok "E3-DEADLOCK no unenumerated tool call is gated before the write" "[ -z \"\$blockedDL\" ]"
ok "E3-DEADLOCK the stale counter is never advanced" "[ \"\$(cat /tmp/baton-nag-${SIDDL} 2>/dev/null)\" = 99 ]"
rm -f "/tmp/baton-nag-${SIDDL}" "/tmp/baton-manual-${SIDDL}" "/tmp/baton-pending-${SIDDL}" \
  "/tmp/claude-context-triggered-${SIDDL}" "/tmp/claude-context-pct-${SIDDL}"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
