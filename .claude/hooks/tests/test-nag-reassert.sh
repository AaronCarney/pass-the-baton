#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
HOOK="$REPO/.claude/hooks/context-checkpoint.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export USER="${USER:-tester}"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }
th(){ bash -c "source $REPO/.claude/hooks/lib/workstream-lib.sh && term_hash"; }
run_hook(){ # sid tool file_path
  printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "$TMP" "${2:-Bash}" "${3:-}" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null
}
clean(){ rm -f "/tmp/claude-context-pct-$1" "/tmp/claude-context-triggered-$1" \
  "/tmp/baton-pending-$1" "/tmp/baton-done-$1" \
  "/tmp/baton-nag-$1" "/tmp/baton-health-$1" "/tmp/baton-warned-$1"; }

# 1. Soft re-assert reminder emitted (attempt 1, below the nag limit).
sid="nag-soft-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
out=$(run_hook "$sid")
ok "soft re-assert emits additionalContext" "printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "soft re-assert has no permissionDecision" "! printf '%s' \"\$out\" | grep -q permissionDecision"
clean "$sid"

# 1b. DONE guard fires even BELOW threshold (proves it sits above the threshold exit).
sid="done-below-$$"; clean "$sid"
echo 5 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/baton-done-${sid}"
out=$(run_hook "$sid")
ok "DONE deny fires below threshold" "printf '%s' \"\$out\" | grep -q 'Checkpoint complete'"
ok "DONE below threshold is a deny" "printf '%s' \"\$out\" | grep -q deny"
clean "$sid"

# 2. Re-assert still fires when % dipped BELOW threshold (the restructure).
sid="nag-below-$$"; clean "$sid"
echo 5 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
out=$(run_hook "$sid")
ok "re-assert fires below threshold while owed" "printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL PENDING'"
clean "$sid"

# 3. Automated path never hard-denies, even with a stale counter at the old limit.
#    Pre-E1 this asserted a deny once the nag counter reached the limit. E1 removed
#    that escalation on the automated (no baton-manual marker) path: it emits the
#    soft write instruction instead and does not advance the stale counter.
sid="nag-hard-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
echo 2 > "/tmp/baton-nag-${sid}"
out=$(run_hook "$sid")
ok "automated path emits the soft write instruction at the old limit" "printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "automated path does not deny at the old limit" "! printf '%s' \"\$out\" | grep -q deny"
ok "automated path does not advance the stale counter" "[ \"$(cat /tmp/baton-nag-${sid} 2>/dev/null)\" = 2 ]"
clean "$sid"

# 4. Fresh below-threshold call with nothing owed: no trigger, no pending flag.
sid="nag-fresh-$$"; clean "$sid"
echo 5 > "/tmp/claude-context-pct-${sid}"
run_hook "$sid" >/dev/null
ok "below threshold + unset FLAG: no pending flag created" "[ ! -e /tmp/baton-pending-${sid} ]"
clean "$sid"

# 5. Trigger path writes the pending flag and refreshes the parent-sid map.
sid="nag-trig-$$"
export CLAUDE_TERMINAL_ID="nag-trig-term-$$"
TH=$(th)
clean "$sid"
# Seed a POPULATED map and backdate its mtime so the trigger's touch is observable two ways:
# content must survive (kills a `: > file` truncation) and mtime must advance (kills a removed touch).
echo "PARENT_SENTINEL_${sid}" > "/tmp/claude-parent-sid-${TH}"
touch -d "@$(( $(date -u +%s) - 7200 ))" "/tmp/claude-parent-sid-${TH}"
_psid_before=$(stat -c %Y "/tmp/claude-parent-sid-${TH}" 2>/dev/null || echo 0)
mkdir -p "$TMP/share/templates"
cp "$REPO/share/templates/free.md" "$TMP/share/templates/free.md" 2>/dev/null || echo '# stub free' > "$TMP/share/templates/free.md"
echo 50 > "/tmp/claude-context-pct-${sid}"
printf '{"session_id":"%s","cwd":"%s","tool_name":"Edit","tool_input":{}}' "$sid" "$TMP" \
  | CLAUDE_PROJECT_DIR="$TMP" XDG_CONFIG_HOME="$TMP/.config" bash "$HOOK" >/dev/null 2>&1
ok "trigger writes pending flag" "[ -e /tmp/baton-pending-${sid} ]"
ok "parent-sid content preserved" "[ \"$(cat /tmp/claude-parent-sid-${TH} 2>/dev/null)\" = \"PARENT_SENTINEL_${sid}\" ]"
ok "parent-sid mtime advanced past sweep window" "[ \"$(stat -c %Y /tmp/claude-parent-sid-${TH} 2>/dev/null || echo 0)\" -gt \"$_psid_before\" ]"
clean "$sid"; rm -f "/tmp/claude-parent-sid-${TH}"

# 6. Progress-file Write is exempt from the nag even past the hard-deny limit (never blocks the save).
sid="nag-exempt-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
echo 5 > "/tmp/baton-nag-${sid}"   # already past the hard-deny limit
# shellcheck disable=SC2034  # used inside the eval'd assert conditions below
out=$(run_hook "$sid" Write "$TMP/progress-testws.md")
ok "progress-file Write is not denied" "! printf '%s' \"\$out\" | grep -q deny"
ok "progress-file Write emits no nag text" "! printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL'"
ok "progress-file Write does not increment nag" "[ \"$(cat /tmp/baton-nag-${sid} 2>/dev/null)\" = 5 ]"
clean "$sid"

# 7. Reading the scaffold is exempt from the nag even past the hard-deny limit.
#    (The checkpoint workflow mandates this read; blocking it deadlocks the save.)
sid="nag-read-scaffold-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
echo 5 > "/tmp/baton-nag-${sid}"   # already past the hard-deny limit
out=$(run_hook "$sid" Read "$TMP/progress-testws-abc123.scaffold.md")
ok "scaffold Read is not denied" "! printf '%s' \"\$out\" | grep -q deny"
ok "scaffold Read does not increment nag" "[ \"$(cat /tmp/baton-nag-${sid} 2>/dev/null)\" = 5 ]"
clean "$sid"

# 8. Reading the active template is exempt from the nag even past the hard-deny limit.
sid="nag-read-tpl-$$"; clean "$sid"
mkdir -p "$TMP/share/templates"
echo '# stub free' > "$TMP/share/templates/free.md"   # makes the resolver land here (precedence 3)
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
echo 5 > "/tmp/baton-nag-${sid}"
out=$(run_hook "$sid" Read "$TMP/share/templates/free.md")
ok "template Read is not denied" "! printf '%s' \"\$out\" | grep -q deny"
ok "template Read does not increment nag" "[ \"$(cat /tmp/baton-nag-${sid} 2>/dev/null)\" = 5 ]"
clean "$sid"

# 9. Automated path: an unrelated Read past the old limit is NOT denied either.
#    Pre-E1 the unrelated Read fell through to the generic hard deny. E1's automated
#    branch sits just above that deny and short-circuits it with the soft write
#    instruction. The scaffold/template Read exemptions (cases 7, 8) still exit ABOVE
#    the E1 branch, so this is not a blanket Read allow.
sid="nag-read-other-$$"; clean "$sid"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}"
touch "/tmp/baton-pending-${sid}"
echo 5 > "/tmp/baton-nag-${sid}"
out=$(run_hook "$sid" Read "$TMP/some-other-file.md")
ok "unrelated Read past the limit is not denied on the automated path" "! printf '%s' \"\$out\" | grep -q deny"
ok "unrelated Read past the limit gets the soft write instruction" "printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL PENDING'"
clean "$sid"

# E3: the nag is IMPOSSIBLE before the write, not merely dodged by enumerated cases.
# Drives the MANUAL path (baton-manual marker present), which is the only path that
# ever counted or escalated. A stale counter well past the old limit is seeded to prove
# the escalation is gone structurally, not just unreached.
sid="e3-manual-$$"; clean "$sid"; rm -f "/tmp/baton-manual-${sid}"
echo 50 > "/tmp/claude-context-pct-${sid}"
touch "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" \
      "/tmp/baton-manual-${sid}"
echo 99 > "/tmp/baton-nag-${sid}"   # far past the retired limit
out=$(run_hook "$sid" Bash)
ok "E3 manual path never denies while owed"        "! printf '%s' \"\$out\" | grep -q deny"
ok "E3 manual path emits no permissionDecision"    "! printf '%s' \"\$out\" | grep -q permissionDecision"
ok "E3 manual path still nudges"                   "printf '%s' \"\$out\" | grep -q 'CHECKPOINT STILL PENDING'"
ok "E3 no counter is written"                      "[ \"\$(cat /tmp/baton-nag-${sid} 2>/dev/null)\" = 99 ]"

# Repeat calls must not accumulate anything. Ten consecutive consequential calls,
# every one of them clean: this is what 'impossible', rather than 'budgeted', means.
_e3_denies=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s' "$(run_hook "$sid" Bash)" | grep -q deny && _e3_denies=$((_e3_denies+1))
done
ok "E3 ten consecutive owed calls never escalate" "[ \"$_e3_denies\" = 0 ]"
clean "$sid"; rm -f "/tmp/baton-manual-${sid}"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
