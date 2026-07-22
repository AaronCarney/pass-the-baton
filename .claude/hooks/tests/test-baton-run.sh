#!/bin/bash
# E6-T2: baton-run.sh - the external fresh-relaunch supervisor. No real claude is
# involved: the wrapper resolves its binary via ${_CLAUDE_BIN:-claude} (a test seam,
# underscore-private - a BATON_* name would be a public promise we owe users), and
# each case injects a fake that counts its own launches and decides whether to leave
# a relaunch marker behind.
#
# Every case gets its OWN count file and OWN BATON_RELAUNCH_LOG. The fake only ever
# increments, and every assert grades an ABSOLUTE count, so a shared count file makes
# case 2 read 3 against an asserted 1 and a CORRECT wrapper goes red. The default log
# path is shared with tasks 3/7/8 and real usage, so stale lines would make the grep
# asserts pass without proving anything.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WRAPPER="$ROOT/tools/baton-run.sh"
PASS=0
FAIL=0
FAILED_CASES=()

# Lifted verbatim from test-auto-continue-spawn.sh:14.
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
_case_dir() { local d="$TMP/$1"; mkdir -p "$d"; echo "$d"; }

# term-hash recomputed in-test to predict the request path (test-auto-continue-spawn.sh:70).
_th() { printf '%s:%s' "${USER:-x}" "$1" | md5sum | cut -d' ' -f1; }

# Fake claude: touches the marker on its FIRST run only, then exits.
make_fake() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
[ "$n" -eq 1 ] && : > "$BATON_RELAUNCH_REQ"
exit 0
EOF
chmod +x "$1"; }

# Never leaves a marker - a user-initiated exit.
make_fake_never() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
exit 0
EOF
chmod +x "$1"; }

# Marks on EVERY run - only the cap can end this loop.
make_fake_always() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
: > "$BATON_RELAUNCH_REQ"
exit 0
EOF
chmod +x "$1"; }

# Marks, then dies with 143 as claude does under SIGTERM (MEASURED 2026-07-14 run 1).
make_fake_143() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
[ "$n" -eq 1 ] && { : > "$BATON_RELAUNCH_REQ"; exit 143; }
exit 0
EOF
chmod +x "$1"; }

# Records argv. One line - `printf '%s\n' "$@"` would split the tokens across lines
# and the '--foo bar' grep would never match.
make_fake_args() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
echo "$@" > "$ARGS_FILE"
exit 0
EOF
chmod +x "$1"; }

# Records the env it inherited AND its own parent - that parent IS the supervisor, so
# it is the value BATON_RELAUNCH_SUPERVISOR must equal. Liveness is recorded here, in
# the only window where it means anything: while claude runs is exactly when the
# helper's `pgrep -P $BATON_RELAUNCH_SUPERVISOR` has to resolve it.
make_fake_env() { cat > "$1" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$COUNT_FILE"
echo "$BATON_RELAUNCH_SUPERVISOR" > "$SUP_FILE"
echo "$PPID" > "$WRAPPER_PID_FILE"
echo "$BATON_RELAUNCH_REQ" > "$REQ_FILE"
echo "$CLAUDE_TERMINAL_ID" >> "$IDS_FILE"
kill -0 "$BATON_RELAUNCH_SUPERVISOR" 2>/dev/null && echo 1 > "$ALIVE_FILE"
[ "$n" -eq 1 ] && : > "$BATON_RELAUNCH_REQ"
exit 0
EOF
chmod +x "$1"; }

# ---------------------------------------------------------------------------
# 1. relaunches exactly once, then stops (marker absent on run 2)
d=$(_case_dir relaunch-once); make_fake "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="once-$$" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  bash "$WRAPPER" >/dev/null 2>&1
)
assert "relaunch-once" "[ \"\$(cat $d/count)\" = 2 ]"
assert "logs-relaunch" "grep -q 'relaunch iter=1' $d/log"

# 2. no marker at all -> single run, no relaunch
d=$(_case_dir no-marker); make_fake_never "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="nomark-$$" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  bash "$WRAPPER" >/dev/null 2>&1
)
assert "no-marker-single-run" "[ \"\$(cat $d/count)\" = 1 ]"

# 3. marker EVERY run -> capped at BATON_RELAUNCH_MAX+1 launches, not infinite.
#    The cap counts RELAUNCHES, so total launches = max+1.
d=$(_case_dir cap); make_fake_always "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="cap-$$" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  export BATON_RELAUNCH_MAX=3
  bash "$WRAPPER" >/dev/null 2>&1
)
assert "cap-honored" "[ \"\$(cat $d/count)\" = 4 ]"
assert "logs-cap" "grep -q 'stop-relaunch-cap-reached' $d/log"

# 3b. non-numeric cap -> fails CLOSED to the default 10, NOT unbounded. Deleting the
#     guard makes this case relaunch forever; `timeout` is the only thing to end it.
d=$(_case_dir bad-cap); make_fake_always "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="badcap-$$" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  export BATON_RELAUNCH_MAX=ten
  timeout 60 bash "$WRAPPER" >/dev/null 2>&1
)
assert "bad-cap-fails-closed" "[ \"\$(cat $d/count)\" = 11 ]"
assert "bad-cap-logged" "grep -q warn-bad-relaunch-max $d/log"

# 4. stale marker from a PREVIOUS run is swept, never honored. The wrapper assigns
#    BATON_RELAUNCH_REQ unconditionally (it OWNS the path), so the path cannot be
#    injected via env - plant it at the path the wrapper will actually compute, via
#    the one seam that IS injectable (CLAUDE_TERMINAL_ID, assigned with :=).
d=$(_case_dir stale); make_fake_never "$d/claude"
_tid="stale-test-$$"
PLANTED="$d/baton-relaunch-$(_th "$_tid")"
: > "$PLANTED"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="$_tid" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  bash "$WRAPPER" >/dev/null 2>&1
)
assert "stale-marker-ignored" "[ \"\$(cat $d/count)\" = 1 ]"
assert "stale-marker-cleared" "[ ! -e '$PLANTED' ]"

# 5. exit code 143 (SIGTERM death) with a marker still relaunches. The wrapper must
#    key on the marker, NEVER on the exit code, or a signal-death reads as a failure.
d=$(_case_dir sigterm); make_fake_143 "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="sig-$$" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  bash "$WRAPPER" >/dev/null 2>&1
)
assert "143-relaunches" "[ \"\$(cat $d/count)\" = 2 ]"

# 6. the exported contract (2->4). Assert VALUES, not truthiness: [ -n "$SUP" ] passes
#    for BATON_RELAUNCH_SUPERVISOR=yes, which makes the helper's `pgrep -P yes` resolve
#    nothing and silently no-op the driver forever.
d=$(_case_dir env); make_fake_env "$d/claude"
_tid="env-$$"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="$_tid" _CLAUDE_BIN="$d/claude"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  export SUP_FILE="$d/sup" WRAPPER_PID_FILE="$d/wpid" REQ_FILE="$d/req"
  export IDS_FILE="$d/ids" ALIVE_FILE="$d/alive"
  bash "$WRAPPER" >/dev/null 2>&1
)
# Nothing else writes wpid; an unwritten one would make this compare two empty
# strings and pass vacuously, so its non-emptiness is part of the assert.
assert "supervisor-is-real-pid" "[ -s $d/wpid ] && [ \"\$(cat $d/sup)\" = \"\$(cat $d/wpid)\" ]"
assert "supervisor-is-alive" "[ \"\$(cat $d/alive 2>/dev/null)\" = 1 ]"
assert "req-exported" "[ -n \"\$(cat $d/req)\" ]"
# Proves Decision 3: a session-keyed path would be swept by cleanup-on-exit and the
# driver would never fire.
assert "req-is-terminal-keyed" "[ \"\$(cat $d/req)\" = \"$d/baton-relaunch-$(_th "$_tid")\" ]"
assert "terminal-id-stable" "[ \"\$(sort -u $d/ids | wc -l)\" = 1 ]"

# 7. args pass through untouched
d=$(_case_dir args); make_fake_args "$d/claude"
(
  export COUNT_FILE="$d/count" BATON_RELAUNCH_LOG="$d/log" TMPDIR="$d"
  export CLAUDE_TERMINAL_ID="args-$$" _CLAUDE_BIN="$d/claude" ARGS_FILE="$d/args"
  export BATON_AUTO_CONTINUE_MODE=relaunch
  bash "$WRAPPER" --foo bar >/dev/null 2>&1
)
assert "args-passthrough" "grep -q -- '--foo bar' $d/args"

rm -rf "$TMP"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
