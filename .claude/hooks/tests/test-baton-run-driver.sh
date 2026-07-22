#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
RUN="$REPO/tools/baton-run.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; fi; }

# Fake claude records its argv AND the supervisor env (locks the decoupling: only
# the relaunch driver may set BATON_RELAUNCH_SUPERVISOR). Fake tmux answers -V
# (version gate in _run_tmux) and otherwise records its argv. Neither runs the other.
printf '#!/usr/bin/env bash\nprintf "claude %%s [sup=%%s]\n" "$*" "${BATON_RELAUNCH_SUPERVISOR:-}" >> "$RECORD"\n' > "$TMP/claude"
printf '#!/usr/bin/env bash\ncase "$1" in -V) echo "tmux ${FAKE_TMUX_VER:-3.4}";; *) printf "tmux %%s\n" "$*" >> "$RECORD";; esac\n' > "$TMP/tmux"
chmod +x "$TMP/claude" "$TMP/tmux"

# BATON_AUTO_CONTINUE_MODE env has highest precedence in _cfg::auto_continue_mode.
# off -> plain claude passthrough, and NO supervisor signal leaks.
: > "$TMP/rec"
BATON_AUTO_CONTINUE_MODE=off RECORD="$TMP/rec" _CLAUDE_BIN="$TMP/claude" _TMUX_BIN="$TMP/tmux" TMUX="" bash "$RUN" --foo
ok "off execs claude with args" "grep -q 'claude --foo' \"$TMP/rec\""
ok "off carries no supervisor signal" "grep -q '\[sup=\]' \"$TMP/rec\""

# tmux mode, NOT inside tmux -> tmux new-session carrying claude+args
: > "$TMP/rec"
BATON_AUTO_CONTINUE_MODE=tmux RECORD="$TMP/rec" _CLAUDE_BIN="$TMP/claude" _TMUX_BIN="$TMP/tmux" TMUX="" bash "$RUN" --foo
ok "tmux (outside) starts tmux new-session" "grep -q 'tmux new-session' \"$TMP/rec\""
ok "tmux new-session carries claude+args" "grep -q 'claude --foo' \"$TMP/rec\""
ok "tmux new-session sets injector opt-in" "grep -q 'BATON_AUTO_CONTINUE=1' \"$TMP/rec\""

# tmux mode, ALREADY inside tmux -> exec claude directly, no tmux relaunch, no supervisor
: > "$TMP/rec"
BATON_AUTO_CONTINUE_MODE=tmux RECORD="$TMP/rec" _CLAUDE_BIN="$TMP/claude" _TMUX_BIN="$TMP/tmux" TMUX="/tmp/tmux-x,1,0" bash "$RUN" --foo
ok "tmux (inside) execs claude" "grep -q 'claude --foo' \"$TMP/rec\""
ok "tmux (inside) does not re-launch tmux" "! grep -q 'tmux new-session' \"$TMP/rec\""
ok "tmux (inside) carries no supervisor signal" "grep -q '\[sup=\]' \"$TMP/rec\""

# tmux mode but tmux too OLD for 'new-session -e' (< 3.0) -> fall back to claude + warn
: > "$TMP/rec"
FAKE_TMUX_VER=2.9 BATON_AUTO_CONTINUE_MODE=tmux RECORD="$TMP/rec" _CLAUDE_BIN="$TMP/claude" _TMUX_BIN="$TMP/tmux" TMUX="" bash "$RUN" --foo 2>"$TMP/err"
ok "old tmux falls back to claude" "grep -q 'claude --foo' \"$TMP/rec\""
ok "old tmux does not run new-session" "! grep -q 'tmux new-session' \"$TMP/rec\""
ok "old tmux warns about version" "grep -qi 'need >= 3.0' \"$TMP/err\""

# tmux mode but tmux binary missing -> fall back to claude + warn
: > "$TMP/rec"
BATON_AUTO_CONTINUE_MODE=tmux RECORD="$TMP/rec" _CLAUDE_BIN="$TMP/claude" _TMUX_BIN="$TMP/nope-tmux" TMUX="" bash "$RUN" --foo 2>"$TMP/err"
ok "tmux missing falls back to claude" "grep -q 'claude --foo' \"$TMP/rec\""
ok "tmux missing warns" "grep -qi 'not installed' \"$TMP/err\""

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
