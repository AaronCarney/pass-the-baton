#!/bin/bash
# E6-T8: the ONE test that composes the real chain. Everything is real code - the
# real wrapper (tools/baton-run.sh), the real Stop hook, the real helper, the real
# mode resolver - and only `claude` itself is stubbed. Every other test in this
# epoch stubs its neighbour (T2 fakes claude, T3 fakes the supervisor, T4 stubs the
# helper), so this is the automated stand-in for T7 Step 6's manual smoke test: if
# that step is deferred, this is the entire gate on whether the wiring does anything.
#
# The COMPOSITION is the value. Do not re-assert what the unit tests already cover:
# one happy path through the whole chain, plus the one MODE=off no-op that proves
# the chain is gated.
set -u

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

d=$(mktemp -d)

# Pin terminal identity so we can PREDICT the wrapper's req path (test-auto-continue-spawn.sh:70
# idiom; matches workstream-lib.sh's `printf '%s:%s' "$USER" "$CLAUDE_TERMINAL_ID" | md5sum`).
# baton-run.sh OWNS BATON_RELAUNCH_REQ and assigns it unconditionally from term_hash, so the
# test shell cannot inject it - and left undefined, `[ ! -e "$REQ" ]` becomes `[ ! -e "" ]`,
# which is ALWAYS TRUE: a guaranteed vacuous pass.
export CLAUDE_TERMINAL_ID=integ-$$
_th=$(printf '%s:%s' "${USER:-x}" "$CLAUDE_TERMINAL_ID" | md5sum | cut -d' ' -f1)
REQ="${TMPDIR:-/tmp}/baton-relaunch-${_th}"
# Run-scoped log: never the shared default, or stale lines from an earlier suite run make
# hook-really-armed/helper-really-ran pass without this test proving anything, and a
# degraded-sigkill written by some other test fails no-sigkill spuriously. Left unset,
# `grep -q armed $BATON_RELAUNCH_LOG` becomes a bare `grep -q armed` reading STDIN - a hang.
export BATON_RELAUNCH_LOG="$d/integ.log"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root; the stub sources the REAL hook from it
export COUNT_FILE="$d/count" SIDS_FILE="$d/sids" REPO_DIR   # stub reads these from its env
[ -f "$REPO_DIR/.claude/hooks/stop-relaunch-trigger.sh" ] || { echo "REPO_DIR wrong: $REPO_DIR"; exit 1; }   # bare export = hook path resolves to /.claude/... and never fires
: > "$COUNT_FILE"   # reset between the happy-path and MODE=off cases - both grade `cat $COUNT_FILE`
# Nothing here is hermetic by default: sweep the stub's leftovers. NOTE the pkill matches
# the STUB's cmdline, not its `sleep` child (whose cmdline is just `sleep 30`), so an
# orphaned sleep can outlive the suite. Harmless - nothing waits on it and it self-expires
# - but do not read this trap as a full child sweep.
trap 'rm -f /tmp/baton-done-integ-* /tmp/baton-done-integ-*.relaunch-fired "$REQ"; pkill -f "$d/claude" 2>/dev/null' EXIT   # NOT -P $$: the stub is a GRANDchild (wrapper owns it)

# The stub IS the `claude` the wrapper launches: named `claude` so the helper's
# `pgrep -P <sup> claude` resolves it, and a direct child of the wrapper by construction.
# MEASURED, not reasoned (local-only evidence, not committed): for a SHEBANG SCRIPT named
# `claude`, `comm` is `claude` (Linux
# sets it from the executed file's basename), `pgrep -P <parent> claude` resolves it rc=0,
# and `pgrep -P <parent> bash` does NOT match it rc=1 - the interpreter does not shadow the
# name. SIGTERM to that stub landed in 1ms (no trap is set here, so bash does not defer the
# signal while waiting on the foreground sleep). This is the ONLY place the property is
# load-bearing: Task 3's fake is `cp /bin/sleep claude`, a real binary that matches by
# construction, so this suite is the only one that could expose it being false.
# The heredoc is QUOTED, so $COUNT_FILE / $SIDS_FILE / $REPO_DIR / $STUB_SLEEP resolve at
# RUN time from the stub's inherited env - which is why they are exported.
# Run 1: simulate a checkpointed turn - write the done-flag, then fire the REAL Stop hook
# with a real payload on stdin, then idle so there is something alive to SIGTERM.
cat > "$d/claude" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
SID="integ-$$-$n"
if [ "$n" -eq 1 ]; then
  : > "/tmp/baton-done-$SID"            # a checkpoint happened this turn
  printf '{"session_id":"%s","cwd":"/tmp"}' "$SID" \
    | AGENT_SESSION_ID= bash "$REPO_DIR/.claude/hooks/stop-relaunch-trigger.sh"   # REAL hook
  echo "$SID" >> "$SIDS_FILE"
  sleep "$STUB_SLEEP"                   # the helper's SIGTERM lands here
fi
exit 0
EOF
chmod +x "$d/claude"

echo "== happy path: hook -> real helper -> real SIGTERM -> real wrapper relaunch =="
# BATON_RELAUNCH_BIN is deliberately UNSET -> the REAL helper runs.
# _RELAUNCH_SETTLE / _RELAUNCH_GRACE are the underscore-private test seams (design :283-308)
# - set low so the suite does not sleep for seconds. This is exactly what they exist for.
_CLAUDE_BIN="$d/claude" BATON_AUTO_CONTINUE_MODE=relaunch STUB_SLEEP=30 \
  _RELAUNCH_SETTLE=0.2 _RELAUNCH_GRACE=2 \
  timeout 60 bash "$REPO_DIR/tools/baton-run.sh"

# The helper is DETACHED (setsid), so its log write races this asserting shell: the wrapper
# regains control the instant the child dies and can break out of its loop and exit before
# the helper has written its terminal tag. Bounded-poll for that tag before grading the log
# (test-auto-continue-spawn.sh:104-107 idiom). This does NOT weaken the asserts - a tag that
# never lands still fails them, it just fails for the real reason instead of on timing.
# Matching any terminal tag (not just the happy one) means a degraded/noop outcome settles
# immediately rather than burning the whole window.
for _i in $(seq 1 50); do
  grep -qE 'relaunch-requested|degraded-sigkill|noop-|fail-' "$BATON_RELAUNCH_LOG" 2>/dev/null && break
  sleep 0.1
done

# `relaunched-once` = 2 is the whole point: it can only be 2 if the hook armed, the helper
# resolved the right PID, the SIGTERM landed, the marker survived SessionEnd, and the
# wrapper consumed it. Any broken link makes it 1, and the last tag in $BATON_RELAUNCH_LOG
# names the link that broke (`armed` absent = hook gate; `noop-no-claude-child` = pgrep
# targeting; `fail-marker-write` = the req path).
assert "relaunched-once"   "[ "$(cat $COUNT_FILE)" = 2 ]"      # killed, then relaunched, then clean exit
assert "helper-really-ran" "grep -q relaunch-requested $BATON_RELAUNCH_LOG"
assert "hook-really-armed" "grep -q armed $BATON_RELAUNCH_LOG"
assert "no-sigkill"        "! grep -q degraded-sigkill $BATON_RELAUNCH_LOG"  # SIGTERM sufficed
assert "marker-consumed"   "[ ! -e "$REQ" ]"                   # wrapper swept it on relaunch

# Do NOT add a one-terminal-record assert here: terminal records are written only by
# rebind_terminal (workstream-lib.sh:294-303), called only from session-start.sh:227,239
# and project-detect.sh:184. This test stubs `claude`, so SessionStart never fires and no
# record is ever written. The co-tenancy invariant is resolved from read source in the
# design and carries NO automated gate by design (design Decision 4, co-tenancy section).

echo "== gated: MODE=off must not arm, so no kill, so no relaunch =="
# Same stub, same wrapper - only the mode differs. This is what proves the chain above is
# gated rather than simply always-on.
: > "$COUNT_FILE"    # reset, or this compares 3 against 1 and fails for the wrong reason
rm -f "$REQ" /tmp/baton-done-integ-*
# SHORT-SLEEP stub (STUB_SLEEP=1), not the 30s one: nothing kills the stub on this path, so
# the wrapper waits out the full sleep and exits normally - `timeout 60` never fires and a
# 30s sleep would just hang the suite. 1s proves the same thing.
_CLAUDE_BIN="$d/claude" BATON_AUTO_CONTINUE_MODE=off STUB_SLEEP=1 \
  _RELAUNCH_SETTLE=0.2 _RELAUNCH_GRACE=2 \
  timeout 60 bash "$REPO_DIR/tools/baton-run.sh"

assert "mode-off-no-relaunch" "[ "$(cat $COUNT_FILE)" = 1 ]"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases: %s\n' "${FAILED_CASES[*]}"
  echo "--- $BATON_RELAUNCH_LOG ---"
  cat "$BATON_RELAUNCH_LOG" 2>/dev/null
  exit 1
fi
exit 0
