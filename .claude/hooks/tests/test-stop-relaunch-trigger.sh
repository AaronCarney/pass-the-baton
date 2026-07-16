#!/bin/bash
# E6-T4: stop-relaunch-trigger.sh - the Stop hook that arms the fresh-relaunch
# driver. This hook ships to EVERY user, so the NO-OP gate matrix matters more
# than the happy path: no supervisor, no checkpoint this turn, wrong mode, or a
# subagent must all be a fast, silent, exit-0 return.
#
# The helper is stubbed via BATON_RELAUNCH_BIN (spawn-observation idiom lifted
# from test-auto-continue-spawn.sh:61-67,104-107) so we grade the hook's gates
# and its argv contract to tools/baton-relaunch.sh, not a real termination.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/stop-relaunch-trigger.sh"

# Drop any config resolver inherited as an exported bash function, so the
# lib-hidden fallback cases actually exercise the hook's inline fallback.
unset -f _cfg::get _cfg::path _cfg::auto_continue_mode 2>/dev/null || true

PASS=0
FAIL=0
FAILED_CASES=()

# Lifted verbatim from test-auto-continue-spawn.sh:14-24.
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

# SANDBOX FIRST - before any _cfg_write call. lib/config.sh:22-24 resolves the
# config path to ${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json, so an
# unsandboxed _cfg_write would arm the relaunch driver on the REAL install of
# whoever runs this suite. Idiom: test-config-lib.sh:5-8.
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME/baton"
CFG="$XDG_CONFIG_HOME/baton/config.json"
# `_cfg::get KEY DEFAULT CONFIG_KEY` looks up the THIRD arg in config.json, and
# the resolver passes `auto_continue_mode`. Writing the ENV-key spelling here
# (as test-config-lib.sh:18 does for ITS key) would resolve to `off`.
_cfg_write() { printf '{"%s":"%s"}' "$1" "$2" > "$CFG"; }

# Stub helper: records argv + a run marker + one line per invocation.
export STUB_RAN="$TMP/stub.ran"
export STUB_ARGV="$TMP/stub.argv"
export STUB_COUNT="$TMP/stub.count"
cat > "$TMP/stub.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGV"
echo ran >> "$STUB_COUNT"
: > "$STUB_RAN"
STUB
chmod +x "$TMP/stub.sh"

# Lib-hidden copy: same script, at a path where ../../lib/config.sh does not
# exist - i.e. plugin distribution, where the inline fallback is the resolver.
HOOK_ISO="$TMP/iso/.claude/hooks/stop-relaunch-trigger.sh"
mkdir -p "$TMP/iso/.claude/hooks"

RESET() { rm -f "$STUB_RAN" "$STUB_ARGV" "$STUB_COUNT" "$ERRF"; }

SUP_PID=$$
REQ="$TMP/relaunch.req"
: > "$REQ"
LOG="$TMP/relaunch.log"
ERRF="$TMP/stderr"
OUTF="$TMP/stdout"
RCF="$TMP/rc"
declare -A RC=()

_payload() { jq -cn --arg s "$1" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false}'; }

# Run the hook once. $1=case name (records rc), $2=stdin json, $3=extra exports,
# $4=hook path override.
_run() {
  local name="$1" stdin_json="$2" extra="${3:-}" hookpath="${4:-$HOOK}"
  (
    unset AGENT_SESSION_ID BATON_AUTO_CONTINUE BATON_AUTO_CONTINUE_MODE
    unset BATON_RELAUNCH_SUPERVISOR BATON_RELAUNCH_REQ
    export BATON_RELAUNCH_BIN="$TMP/stub.sh"
    export BATON_RELAUNCH_LOG="$LOG"
    [ -n "$extra" ] && eval "$extra"
    printf '%s' "$stdin_json" | bash "$hookpath" >"$OUTF" 2>"$ERRF"
    echo "$?" > "$RCF"
  )
  RC[$name]="$(cat "$RCF")"
}

# Standard armed env: supervisor + req + relaunch mode.
ARMED="export BATON_RELAUNCH_SUPERVISOR=$SUP_PID; export BATON_RELAUNCH_REQ='$REQ'; export BATON_AUTO_CONTINUE_MODE=relaunch"

# The hook detaches via `setsid ... &`, so the stub's write can land AFTER the
# hook returns (test-auto-continue-spawn.sh:104-107).
_poll()   { local i; for i in $(seq 1 50); do [ -f "$STUB_RAN" ] && break; sleep 0.1; done; }
_settle() { sleep 0.5; }   # give a WRONG spawn time to appear before a negative assert

echo "## happy path"
rm -f "$CFG"
RESET
SID="s-happy-$$"
DONE="/tmp/baton-done-$SID"
rm -f "$DONE" "$DONE.relaunch-fired"
: > "$DONE"
_run happy "$(_payload "$SID")" "$ARMED"
_poll
assert "spawns-helper"   "[ -f '$STUB_RAN' ]"
assert "fired-marker"    "[ -f '$DONE.relaunch-fired' ]"
assert "doneflag-intact" "[ -f '$DONE' ]"
assert "logs-armed"      "grep -q 'armed sid=$SID' '$LOG'"

# argv contract (3->4). Nothing else grades the ORDER the HOOK passes.
assert "argv1-is-session-id"  "[ \"\$(sed -n 1p '$STUB_ARGV')\" = '$SID' ]"
assert "argv2-is-supervisor"  "[ \"\$(sed -n 2p '$STUB_ARGV')\" = '$SUP_PID' ]"
assert "argv2-is-numeric-pid" "[[ \"\$(sed -n 2p '$STUB_ARGV')\" =~ ^[0-9]+$ ]]"
assert "argv3-is-req-path"    "[ \"\$(sed -n 3p '$STUB_ARGV')\" = '$REQ' ]"

# fire-once: a second Stop on the same done-flag does NOT re-spawn.
_run happy2 "$(_payload "$SID")" "$ARMED"
_settle
assert "fires-once"           "[ \"\$(wc -l < '$STUB_COUNT')\" = '1' ]"
assert "doneflag-intact-after-refire" "[ -f '$DONE' ]"
rm -f "$DONE" "$DONE.relaunch-fired"

echo "## ships-safe no-op gates"

# No supervisor: the plain-`claude` path. Every user who never runs baton-run.
RESET
SID="s-nosup-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run no-supervisor "$(_payload "$SID")" "export BATON_RELAUNCH_REQ='$REQ'; export BATON_AUTO_CONTINUE_MODE=relaunch"
_settle
assert "no-supervisor-noop"   "[ ! -f '$STUB_RAN' ]"
assert "no-supervisor-silent" "[ ! -s '$ERRF' ]"
rm -f "$DONE"

# Supervisor set but no request path -> nothing could consume a relaunch.
RESET
SID="s-noreq-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run no-req "$(_payload "$SID")" "export BATON_RELAUNCH_SUPERVISOR=$SUP_PID; export BATON_AUTO_CONTINUE_MODE=relaunch"
_settle
assert "no-req-noop" "[ ! -f '$STUB_RAN' ]"
rm -f "$DONE"

# No checkpoint this turn - the overwhelmingly common case.
RESET
SID="s-noflag-$$"
rm -f "/tmp/baton-done-$SID"
_run no-doneflag "$(_payload "$SID")" "$ARMED"
_settle
assert "no-doneflag-noop" "[ ! -f '$STUB_RAN' ]"

# Wrong mode.
RESET
SID="s-tmux-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run tmux-mode "$(_payload "$SID")" \
  "export BATON_RELAUNCH_SUPERVISOR=$SUP_PID; export BATON_RELAUNCH_REQ='$REQ'; export BATON_AUTO_CONTINUE_MODE=tmux"
_settle
assert "tmux-mode-noop" "[ ! -f '$STUB_RAN' ]"
rm -f "$DONE"

RESET
SID="s-off-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run off-mode "$(_payload "$SID")" \
  "export BATON_RELAUNCH_SUPERVISOR=$SUP_PID; export BATON_RELAUNCH_REQ='$REQ'"
_settle
assert "off-mode-noop" "[ ! -f '$STUB_RAN' ]"
rm -f "$DONE"

# Subagent (checkpoint-write-trigger.sh:77 idiom; defense in depth).
RESET
SID="s-sub-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run subagent "$(_payload "$SID")" "$ARMED; export AGENT_SESSION_ID=agent-1"
_settle
assert "subagent-noop" "[ ! -f '$STUB_RAN' ]"
rm -f "$DONE"

# Malformed session_id. The sid must be one the regex REJECTS whose /tmp path is
# REAL, so the done-flag gate WOULD pass and the guard is the ONLY thing left.
# ('../../evil' grades nothing: /tmp/baton-done-.. is not a directory, so the
# done-flag gate rejects it with or without the guard - VERIFIED.)
RESET
BAD_SID='x y'
: > "/tmp/baton-done-$BAD_SID"
_run bad-sid "$(_payload "$BAD_SID")" "$ARMED"
_settle
assert "bad-sid-noop" "[ ! -f '$STUB_RAN' ]"
rm -f "/tmp/baton-done-$BAD_SID" "/tmp/baton-done-$BAD_SID.relaunch-fired"

# Payload with no session_id -> jq yields empty.
RESET
_run empty-sid '{"hook_event_name":"Stop"}' "$ARMED"
_settle
assert "empty-sid-noop" "[ ! -f '$STUB_RAN' ]"

echo "## exit 0 on every path"
# A Stop hook exiting non-zero BLOCKS the stop and forces the model to keep
# working - a hang for the user. Every gate path must return 0.
for c in happy no-supervisor no-doneflag tmux-mode off-mode subagent; do
  assert "exit-zero-$c" "[ '${RC[$c]}' = '0' ]"
done

echo "## committed-path record"
# Past the fire-once claim no path may exit silently: a broken install must not
# look identical to "nothing to do".
RESET
SID="s-nohelper-$$"; DONE="/tmp/baton-done-$SID"; : > "$DONE"
_run no-helper "$(_payload "$SID")" "$ARMED; export BATON_RELAUNCH_BIN='$TMP/does-not-exist.sh'"
assert "logs-fail-helper-missing" "grep -q 'fail-helper-missing sid=$SID' '$LOG'"
assert "exit-zero-no-helper"      "[ '${RC[no-helper]}' = '0' ]"
rm -f "$DONE" "$DONE.relaunch-fired"

echo "## lib-unreachable fallback (plugin distribution)"
_with_lib_hidden() { # $1=case name, $2=extra exports
  cp "$HOOK" "$HOOK_ISO"
  RESET
  SID="s-iso-$1-$$"; DONE_ISO="/tmp/baton-done-$SID"
  rm -f "$DONE_ISO" "$DONE_ISO.relaunch-fired"; : > "$DONE_ISO"
  _run "$1" "$(_payload "$SID")" "$2" "$HOOK_ISO"
  _poll; _settle
  rm -f "$DONE_ISO" "$DONE_ISO.relaunch-fired"
}
SUPREQ="export BATON_RELAUNCH_SUPERVISOR=$SUP_PID; export BATON_RELAUNCH_REQ='$REQ'"

rm -f "$CFG"
_with_lib_hidden fb-relaunch "$SUPREQ; export BATON_AUTO_CONTINUE_MODE=relaunch"
assert "fallback-relaunch-fires" "[ -f '$STUB_RAN' ]"

_with_lib_hidden fb-legacy "$SUPREQ; export BATON_AUTO_CONTINUE=1"
assert "fallback-legacy-1-noop" "[ ! -f '$STUB_RAN' ]"

# The config.json layer is what actually matters: `baton-dashboard.sh set
# auto_continue_mode=relaunch` puts the mode in config.json and NOTHING in env.
# An env-only fallback exits 0 forever while the dashboard reports `relaunch` -
# the dashboard-vs-gate disagreement lib/config.sh:6-10 forbids.
_cfg_write auto_continue_mode relaunch
_with_lib_hidden fb-config "$SUPREQ"
assert "fallback-honors-config-json" "[ -f '$STUB_RAN' ]"

# Prove the sandbox took, so a future edit cannot silently reintroduce a write
# to the runner's live config.
assert "config-is-sandboxed" "[ '$CFG' != \"\$HOME/.config/baton/config.json\" ] && [ -f '$CFG' ]"
rm -f "$CFG"

rm -rf "$TMP"
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
fi
[ "$FAIL" -eq 0 ]
