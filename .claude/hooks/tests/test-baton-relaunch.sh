#!/bin/bash
# E6-T3: tools/baton-relaunch.sh - the detached helper the Stop hook spawns. It
# re-resolves the target claude, writes the relaunch marker, then terminates the
# session so the baton-run supervisor can start a fresh one.
#
# Fakes throughout: a fake supervisor (a bash that backgrounds children and waits)
# plus a child literally named `claude`, so nothing real is ever signalled.
#
# NOTE ON WHAT THIS SUITE CAN AND CANNOT PROVE: the fake child is a renamed real
# binary (`cp /bin/sleep .../claude`), so it matches `pgrep -P <sup> claude` BY
# CONSTRUCTION. These tests therefore CANNOT catch a pgrep name-match failure
# against a REAL claude - if that resolution broke, every case here would still
# pass. What covers it: test-relaunch-integration.sh, whose stub is a shebang
# script named `claude` (comm=claude, so `pgrep -P <sup> claude` must genuinely
# resolve it). Measured out-of-band against a real claude: the name matches and
# SIGTERM lands in ~1ms (local-only evidence, not committed).
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RELAUNCH="$ROOT/tools/baton-relaunch.sh"
PASS=0
FAIL=0
FAILED_CASES=()

# Lifted verbatim from test-hook-writers.sh:14,26,35.
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

TMP=$(mktemp -d)
SUPS=()

cleanup() {
  local p c
  for p in "${SUPS[@]:-}"; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
    kill -9 "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# Spawn a fake supervisor running snippet $1; sets global $SUP to its pid.
# stderr silenced + disowned so the shell's "Killed" job reports (ours at cleanup,
# the supervisor's for its own SIGKILLed child) do not pollute the suite output.
_spawn_sup() {
  bash -c "$1" 2>/dev/null &
  SUP=$!
  SUPS+=("$SUP")
  disown "$SUP" 2>/dev/null || true
}

# Bounded-poll until pgrep resolves a child named $2 under supervisor $1.
_wait_child() {
  local n=0 p
  while [ "$n" -lt 100 ]; do
    p=$(pgrep -P "$1" "$2" 2>/dev/null | head -1)
    [ -n "$p" ] && { echo "$p"; return 0; }
    n=$((n+1)); sleep 0.05
  done
  return 1
}

_case_dir() { mkdir -p "$TMP/$1"; echo "$TMP/$1"; }

# Every case gets its OWN $BATON_RELAUNCH_LOG. A shared log makes the count
# asserts order-dependent: `logged-once` counts 1 only if no earlier case already
# wrote that tag, so re-ordering cases would break it for a reason that has
# nothing to do with the helper.

# ---------------------------------------------------------------------------
# 1. Happy path: child dies, marker written, exactly one relaunch-requested line.
# ---------------------------------------------------------------------------
d=$(_case_dir c1); cp /bin/sleep "$d/claude"
LOG="$TMP/log-happy"; REQ="$d/req"
_spawn_sup "'$d/claude' 20 & wait"; SUP1=$SUP
CHILD=$(_wait_child "$SUP1" claude)
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-happy "$SUP1" "$REQ"
assert "child-terminated" "! kill -0 $CHILD 2>/dev/null"
assert "marker-written"   "[ -f $REQ ]"
assert "logged-once"      "[ \$(grep -c relaunch-requested '$LOG') = 1 ]"

# ---------------------------------------------------------------------------
# 2. NO claude child (the user already quit) -> NO marker, logged, exit 0.
#    The phantom-relaunch guard: the marker means "we killed it", not "we meant to".
# ---------------------------------------------------------------------------
d=$(_case_dir c2); cp /bin/sleep "$d/other"
LOG="$TMP/log-nochild"; REQ="$d/req"
_spawn_sup "'$d/other' 20 & wait"; SUP2=$SUP
_wait_child "$SUP2" other >/dev/null
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-nochild "$SUP2" "$REQ"; rc=$?
assert "no-child-no-marker" "[ ! -f $REQ ]"
assert "no-child-logged"    "grep -q noop-no-claude-child '$LOG'"
assert "no-child-exit-0"    "[ $rc = 0 ]"

# ---------------------------------------------------------------------------
# 3. Supervisor has an unrelated child -> not targeted (pgrep filters by name).
#    SPAWN THE BYSTANDER FIRST. With `claude` spawned first it is also the lowest
#    pid, so `pgrep -P $SUP | head -1` and `pgrep -P $SUP claude | head -1` return
#    the SAME pid: the assert would pass with the name constraint deleted and prove
#    nothing. Bystander-first makes the unfiltered call resolve the WRONG process,
#    so only the name filter saves the real child.
# ---------------------------------------------------------------------------
d=$(_case_dir c3); cp /bin/sleep "$d/claude"; cp /bin/sleep "$d/bystander"
LOG="$TMP/log-bystander"; REQ="$d/req"
_spawn_sup "'$d/bystander' 20 & '$d/claude' 20 & wait"; SUP3=$SUP
BYSTANDER=$(_wait_child "$SUP3" bystander)
CHILD=$(_wait_child "$SUP3" claude)
# Guards the premise above: if this ever flips (pid wraparound), the two asserts
# below stop discriminating and would silently pass a name-filter regression.
assert "bystander-is-lower-pid" "[ $BYSTANDER -lt $CHILD ]"
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-by "$SUP3" "$REQ"
assert "bystander-survives" "kill -0 $BYSTANDER"
# Grade BOTH halves: the bystander living proves nothing if the real child lived too.
assert "claude-child-terminated" "! kill -0 $CHILD 2>/dev/null"

# ---------------------------------------------------------------------------
# 4. Hung child ignoring SIGTERM -> SIGKILLed after the grace, logged DEGRADED.
#    _RELAUNCH_GRACE=1 so this does not sleep 5s+ on every suite run.
#    The fake is a copied *bash* with the TERM trap ignored. The busy-wait loop is
#    load-bearing: with a foreground `sleep`, bash exec-optimizes the final command
#    and replaces its own image -> comm becomes `sleep`, which `pgrep -P <sup> claude`
#    cannot match, so the case would silently test nothing. (The ignored trap itself
#    would survive: SIG_IGN is inherited across exec. It is comm that is lost.)
# ---------------------------------------------------------------------------
d=$(_case_dir c4); cp /bin/bash "$d/claude"
LOG="$TMP/log-hung"; REQ="$d/req"
_spawn_sup "'$d/claude' -c 'trap \"\" TERM; while :; do sleep 0.2; done' & wait"; SUP4=$SUP
CHILD=$(_wait_child "$SUP4" claude)
_RELAUNCH_SETTLE=0 _RELAUNCH_GRACE=1 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-hung "$SUP4" "$REQ"
assert "hung-escalated"     "grep -q degraded-sigkill '$LOG'"
assert "hung-not-success"   "! grep -q relaunch-requested '$LOG'"

# ---------------------------------------------------------------------------
# 5. Non-numeric grace -> falls back to the default, NOT straight to SIGKILL.
#    The numeric guard is what makes this hold: `awk -v g=ten 'BEGIN{printf "%d",
#    g/0.25}'` yields 0, so _max=0, the wait loop never runs, and EVERY relaunch
#    SIGKILLs - skipping SessionEnd. Delete the guard and the rest of this suite
#    stays green; these two asserts are what close it. Child DOES exit on SIGTERM.
# ---------------------------------------------------------------------------
d=$(_case_dir c5); cp /bin/sleep "$d/claude"
LOG="$TMP/log-badgrace"; REQ="$d/req"
_spawn_sup "'$d/claude' 20 & wait"; SUP5=$SUP
CHILD=$(_wait_child "$SUP5" claude)
_RELAUNCH_SETTLE=0 _RELAUNCH_GRACE=ten BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-bad "$SUP5" "$REQ"
assert "bad-grace-not-sigkilled" "! grep -q degraded-sigkill '$LOG'"
assert "bad-grace-still-works"   "grep -q relaunch-requested '$LOG'"  # else the above is vacuous

# ---------------------------------------------------------------------------
# 6. fail-sigterm: kill fails (child died in the gap) -> the marker MUST be removed.
#    This rm is the anti-phantom-relaunch guard: without it the wrapper relaunches a
#    session nobody killed. Deleting the rm leaves the rest of the suite green.
#    Inducible ONLY via the _RELAUNCH_KILL seam.
# ---------------------------------------------------------------------------
d=$(_case_dir c6); cp /bin/sleep "$d/claude"
LOG="$TMP/log-failterm"; REQ="$d/req"
STUB="$TMP/kill-failterm"
cat > "$STUB" <<'EOF'
#!/bin/bash
[ "$1" = "-TERM" ] && exit 1   # -0 probes still succeed, so the PID reads as live
exec /bin/kill "$@"
EOF
chmod +x "$STUB"
_spawn_sup "'$d/claude' 20 & wait"; SUP6=$SUP
CHILD=$(_wait_child "$SUP6" claude)
_RELAUNCH_SETTLE=0 _RELAUNCH_KILL="$STUB" BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-ft "$SUP6" "$REQ"
assert "fail-sigterm-unmarks" "[ ! -e $REQ ]"
assert "fail-sigterm-logged"  "grep -q fail-sigterm '$LOG'"

# ---------------------------------------------------------------------------
# 7. fail-marker-write: unwritable REQ path -> no kill at all, logged, exit 0.
#    (Killing without a marker = a session that dies and never comes back.)
#    A nonexistent parent dir, not chmod 000: chmod would not stop a root test run.
# ---------------------------------------------------------------------------
d=$(_case_dir c7); cp /bin/sleep "$d/claude"
LOG="$TMP/log-failmark"; REQ="$d/nodir/req"
_spawn_sup "'$d/claude' 20 & wait"; SUP7=$SUP
CHILD=$(_wait_child "$SUP7" claude)
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-fm "$SUP7" "$REQ"; rc=$?
assert "fail-marker-no-kill" "kill -0 $CHILD"
assert "fail-marker-logged"  "grep -q fail-marker-write '$LOG'"
assert "fail-marker-exit-0"  "[ $rc = 0 ]"

# ---------------------------------------------------------------------------
# 8. noop-child-gone: kill -0 fails while pgrep still resolved a PID -> clean no-op,
#    and NO marker (a marker here would relaunch a session nobody killed).
#    Also only inducible via the _RELAUNCH_KILL seam - a genuine race otherwise.
# ---------------------------------------------------------------------------
d=$(_case_dir c8); cp /bin/sleep "$d/claude"
LOG="$TMP/log-gone"; REQ="$d/req"
GONE_STUB="$TMP/kill-gone"
cat > "$GONE_STUB" <<'EOF'
#!/bin/bash
[ "$1" = "-0" ] && exit 1   # the PID reads as already dead
exec /bin/kill "$@"
EOF
chmod +x "$GONE_STUB"
_spawn_sup "'$d/claude' 20 & wait"; SUP8=$SUP
CHILD=$(_wait_child "$SUP8" claude)
_RELAUNCH_SETTLE=0 _RELAUNCH_KILL="$GONE_STUB" BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" s-gone "$SUP8" "$REQ"
assert "child-gone-logged"    "grep -q noop-child-gone '$LOG'"
assert "child-gone-no-marker" "[ ! -e $REQ ]"
assert "child-gone-survives"  "kill -0 $CHILD"

# ---------------------------------------------------------------------------
# 9. pgrep unavailable -> its OWN tag. Distinct from no-child: a broken host is not
#    a user who quit, and collapsing them misdiagnoses one as the other.
#    /bin/bash by absolute path: `PATH=/nonexistent bash` would fail the lookup.
# ---------------------------------------------------------------------------
LOG="$TMP/log-nopgrep"; REQ="$TMP/c9-req"
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" PATH=/nonexistent \
  /bin/bash "$RELAUNCH" s-np 1 "$REQ" 2>/dev/null; rc=$?
assert "no-pgrep-own-tag"   "grep -q noop-no-pgrep '$LOG'"
assert "no-pgrep-not-quit"  "! grep -q noop-no-claude-child '$LOG'"
assert "no-pgrep-no-marker" "[ ! -e $REQ ]"
assert "no-pgrep-exit-0"    "[ $rc = 0 ]"

# ---------------------------------------------------------------------------
# 10. Missing args -> clean no-op (the hook may fire before the wrapper is set up).
# ---------------------------------------------------------------------------
LOG="$TMP/log-noargs"
_RELAUNCH_SETTLE=0 BATON_RELAUNCH_LOG="$LOG" bash "$RELAUNCH" 2>/dev/null; rc=$?
assert "no-args-exit-0" "[ $rc = 0 ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || printf 'failed: %s\n' "${FAILED_CASES[*]}"
[ "$FAIL" -eq 0 ]
