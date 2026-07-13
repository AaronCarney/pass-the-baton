set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
TMP=$(mktemp -d); export TMUX_LOG="$TMP/tmux.log"; : > "$TMUX_LOG"
export BATON_AUTO_CONTINUE_LOG="$TMP/ac.log"; : > "$BATON_AUTO_CONTINUE_LOG"
mkdir -p "$TMP/bin"
# Mode-driven shim. ready=always idle (fire path); busy=never idle (idle-wait
# timeout); busy_after_clear=idle until /clear is in the log, then busy (models a
# turn that goes busy again -> post-clear prompt-ready timeout).
cat > "$TMP/bin/tmux" <<'SHIM'
#!/bin/bash
echo "$*" >> "$TMUX_LOG"
if [ "$1" = "capture-pane" ]; then
  # Abort simulation: delete the done-flag DURING the idle poll (which runs
  # before the fire-once claim), modelling the documented user abort.
  [ -n "${SHIM_DELETE_FLAG:-}" ] && rm -f "$SHIM_DELETE_FLAG"
  case "${SHIM_MODE:-ready}" in
    busy) echo 'working...' ;;
    busy_after_clear) if grep -q '/clear' "$TMUX_LOG"; then echo 'working...'; else echo '~ $ '; fi ;;
    *) echo '~ $ ' ;;
  esac
fi
# Fail the /clear send on demand, to exercise fail-clear-send with the gate intact.
if [ "$1" = "send-keys" ] && [ -n "${SHIM_FAIL_CLEAR:-}" ]; then
  case "$*" in *"/clear"*) exit 1 ;; esac
fi
exit 0
SHIM
chmod +x "$TMP/bin/tmux"; export PATH="$TMP/bin:$PATH"

# --- Case 1: opt-in ON, ready immediately -> fire once + log `continued` ---
SID=auto-cont-test-1; FLAG="$TMP/baton-done-$SID"; touch "$FLAG"
SHIM_MODE=ready BATON_AUTO_CONTINUE=1 _AUTO_CONTINUE_POLL_MAX_SECONDS=2 \
  bash "$REPO/tools/baton-auto-continue.sh" "$SID" "$FLAG" '%3'
assert "gate-preserved-marker-set" "[ -e '$FLAG' ] && [ -e '$FLAG.fired' ]"
assert "sent-clear"    "grep -q 'send-keys -t %3 /clear Enter' '$TMUX_LOG'"
assert "sent-nudge"    "grep -q 'send-keys -t %3 -l -- proceed' '$TMUX_LOG'"
assert "sent-nudge-enter" "[ \$(grep -c 'send-keys -t %3 Enter' '$TMUX_LOG') -ge 1 ]"
assert "logged-continued" "grep -q 'continued' '$BATON_AUTO_CONTINUE_LOG'"

# --- Case 2: opt-in OFF -> no send, flag untouched, nothing logged (pre-consumption no-op) ---
: > "$BATON_AUTO_CONTINUE_LOG"; : > "$TMUX_LOG"
SID2=auto-cont-test-2; FLAG2="$TMP/baton-done-$SID2"; touch "$FLAG2"
BATON_AUTO_CONTINUE=0 bash "$REPO/tools/baton-auto-continue.sh" "$SID2" "$FLAG2" '%3'
assert "optout-no-send" "[ ! -s '$TMUX_LOG' ] && [ -e '$FLAG2' ]"
assert "optout-no-log"  "[ ! -s '$BATON_AUTO_CONTINUE_LOG' ]"

# --- Case 3: empty pane -> no send (no-tmux degradation) ---
: > "$TMUX_LOG"; SID3=auto-cont-test-3; FLAG3="$TMP/baton-done-$SID3"; touch "$FLAG3"
BATON_AUTO_CONTINUE=1 bash "$REPO/tools/baton-auto-continue.sh" "$SID3" "$FLAG3" ''
assert "nopane-no-send" "[ ! -s '$TMUX_LOG' ] && [ -e '$FLAG3' ]"

# --- Case 4: never idle -> first poll TIMES OUT before consuming the flag ---
# Exercises the wait loop + the noop-idle-wait-timeout branch. Flag MUST survive
# (user still acts manually) and nothing may be sent.
: > "$BATON_AUTO_CONTINUE_LOG"; : > "$TMUX_LOG"
SID4=auto-cont-test-4; FLAG4="$TMP/baton-done-$SID4"; touch "$FLAG4"
SHIM_MODE=busy BATON_AUTO_CONTINUE=1 _AUTO_CONTINUE_POLL_MAX_SECONDS=1 \
  bash "$REPO/tools/baton-auto-continue.sh" "$SID4" "$FLAG4" '%4'
assert "busy-flag-preserved"  "[ -e '$FLAG4' ] && [ ! -e '$FLAG4.fired' ]"
assert "busy-no-clear-sent"   "! grep -q '/clear' '$TMUX_LOG'"
assert "busy-logged-idle-timeout" "grep -q 'noop-idle-wait-timeout' '$BATON_AUTO_CONTINUE_LOG'"

# --- Case 5: idle then busy-after-clear -> /clear sent but nudge poll TIMES OUT ---
# The one consequential failure state: cleared-but-not-continued. Flag consumed to
# .fired, /clear sent, nudge NOT sent, and the state is RECORDED (owner rule).
: > "$BATON_AUTO_CONTINUE_LOG"; : > "$TMUX_LOG"
SID5=auto-cont-test-5; FLAG5="$TMP/baton-done-$SID5"; touch "$FLAG5"
SHIM_MODE=busy_after_clear BATON_AUTO_CONTINUE=1 _AUTO_CONTINUE_POLL_MAX_SECONDS=1 \
  bash "$REPO/tools/baton-auto-continue.sh" "$SID5" "$FLAG5" '%5'
assert "postclear-fired"        "[ -e '$FLAG5.fired' ]"
assert "postclear-sent-clear"   "grep -q 'send-keys -t %5 /clear Enter' '$TMUX_LOG'"
assert "postclear-no-nudge"     "! grep -q 'send-keys -t %5 -l' '$TMUX_LOG'"
assert "postclear-logged-timeout" "grep -q 'cleared-not-continued-prompt-timeout' '$BATON_AUTO_CONTINUE_LOG'"

# --- Case 6: flag deleted during idle poll -> mv aborts, noop-aborted-flag-gone ---
# The documented primary user control: delete the done-flag in the poll window.
# The shim rm's the flag on its first capture-pane (inside _wait_ready, BEFORE the
# fire-once mv), so the mv finds it gone. Nothing may be sent; the abort is logged.
: > "$BATON_AUTO_CONTINUE_LOG"; : > "$TMUX_LOG"
SID6=auto-cont-test-6; FLAG6="$TMP/baton-done-$SID6"; touch "$FLAG6"
SHIM_MODE=ready SHIM_DELETE_FLAG="$FLAG6" BATON_AUTO_CONTINUE=1 _AUTO_CONTINUE_POLL_MAX_SECONDS=2 \
  bash "$REPO/tools/baton-auto-continue.sh" "$SID6" "$FLAG6" '%6'
assert "abort-no-clear-sent" "! grep -q '/clear' '$TMUX_LOG'"
assert "abort-flag-gone"     "[ ! -e '$FLAG6' ] && [ ! -e '$FLAG6.fired' ]"
assert "abort-logged"        "grep -q 'noop-aborted-flag-gone' '$BATON_AUTO_CONTINUE_LOG'"

# --- Case 7 (hardening): /clear send FAILS after fire-once -> the block-gate
# (baton-done) MUST survive so the still-live session stays guarded. Regression for
# the seam where the injector consumed the gate flag as its fire-once token: a
# failed /clear then left the session with no "do not continue working" block.
: > "$BATON_AUTO_CONTINUE_LOG"; : > "$TMUX_LOG"
SID7=auto-cont-test-7; FLAG7="$TMP/baton-done-$SID7"; touch "$FLAG7"
SHIM_MODE=ready SHIM_FAIL_CLEAR=1 BATON_AUTO_CONTINUE=1 _AUTO_CONTINUE_POLL_MAX_SECONDS=2 \
  bash "$REPO/tools/baton-auto-continue.sh" "$SID7" "$FLAG7" '%7'
assert "failclear-gate-preserved" "[ -e '$FLAG7' ]"
assert "failclear-fired-claimed"  "[ -e '$FLAG7.fired' ]"
assert "failclear-logged"         "grep -q 'fail-clear-send' '$BATON_AUTO_CONTINUE_LOG'"
assert "failclear-not-continued"  "! grep -q 'continued' '$BATON_AUTO_CONTINUE_LOG'"

rm -rf "$TMP"; echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
