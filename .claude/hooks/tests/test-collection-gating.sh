#!/usr/bin/env bash
# test-collection-gating.sh - E23/CC19: collection is off by default; arc OR collect-flag opens it; DISABLE is the hard kill-switch.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
ok(){ PASS=$((PASS+1)); }

setup(){
  TMP="$(mktemp -d)"
  export XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config"
  export BATON_EVENT_LOG="$TMP/events.jsonl"
  export CLAUDE_TERMINAL_ID="gate-test-$$"
  unset BATON_EVENT_LOG_DISABLE BATON_COLLECT
}
emit_one(){ ( source "$REPO/.claude/hooks/lib/envelope.sh"; envelope::emit test_event '{"k":1}'; ); }
# Count only OUR test_event lines: open_arc's mark-start emits its own project_boundary
# event into the same log once the arc gate is open, which is not what we are gating on.
# grep -c exits 1 on zero matches but still prints 0; capture that single integer cleanly.
count(){ [ -f "$BATON_EVENT_LOG" ] || { echo 0; return; }; grep -c '"event":"test_event"' "$BATON_EVENT_LOG" || true; }
open_arc(){ "$REPO/tools/project.sh" mark-start "$1" --method gate-test >/dev/null 2>&1; }
close_arc(){ "$REPO/tools/project.sh" mark-end "$1" --status success >/dev/null 2>&1; }

# 1. default: no arc, no flag, no disable -> NO event
setup; emit_one; [ "$(count)" = 0 ] && ok || fail 'default-off should emit nothing'

# 2. global flag via env -> event emitted
setup; BATON_COLLECT=1 emit_one; [ "$(count)" = 1 ] && ok || fail 'BATON_COLLECT=1 should emit'

# 3. global flag via config.json (verbatim BATON_COLLECT key) -> event emitted
setup; mkdir -p "$XDG_CONFIG_HOME/baton"; printf '{"BATON_COLLECT":"1"}' > "$XDG_CONFIG_HOME/baton/config.json"; emit_one; [ "$(count)" = 1 ] && ok || fail 'config BATON_COLLECT=1 should emit'

# 4. arc open, no flag -> event emitted AND stamped (BOTH project_slug AND method).
setup; open_arc gate-arc; emit_one; n=$(count); slug=$([ -f "$BATON_EVENT_LOG" ] && jq -r 'select(.event=="test_event").data.project_slug // ""' "$BATON_EVENT_LOG" | tail -1); meth=$([ -f "$BATON_EVENT_LOG" ] && jq -r 'select(.event=="test_event").data.method // ""' "$BATON_EVENT_LOG" | tail -1); close_arc gate-arc; { [ "$n" = 1 ] && [ "$slug" = gate-arc ] && [ "$meth" = gate-test ]; } && ok || fail 'open arc should emit + stamp project_slug AND method'

# 5. DISABLE=1 with an OPEN arc -> NO event (hard kill-switch wins)
setup; open_arc kill-arc; BATON_EVENT_LOG_DISABLE=1 emit_one; n=$(count); close_arc kill-arc; [ "$n" = 0 ] && ok || fail 'DISABLE must override an open arc'

# 6. DISABLE=1 with collect flag -> NO event
setup; BATON_EVENT_LOG_DISABLE=1 BATON_COLLECT=1 emit_one; [ "$(count)" = 0 ] && ok || fail 'DISABLE must override collect flag'

# 7. env-only fallback branch (config.sh UNREACHABLE): env BATON_COLLECT=1 still gates on.
setup; FBDIR="$TMP/fb/.claude/hooks/lib"; mkdir -p "$FBDIR"; cp "$REPO/.claude/hooks/lib/envelope.sh" "$FBDIR/"; ( source "$FBDIR/envelope.sh"; BATON_COLLECT=1 envelope::emit test_event '{"k":1}'; ); [ "$(count)" = 1 ] && ok || fail 'fallback: env BATON_COLLECT=1 should emit'

# 8. env-only fallback branch: config.json BATON_COLLECT=1 still gates on.
setup; FBDIR="$TMP/fb/.claude/hooks/lib"; mkdir -p "$FBDIR"; cp "$REPO/.claude/hooks/lib/envelope.sh" "$FBDIR/"; mkdir -p "$XDG_CONFIG_HOME/baton"; printf '{"BATON_COLLECT":"1"}' > "$XDG_CONFIG_HOME/baton/config.json"; ( source "$FBDIR/envelope.sh"; envelope::emit test_event '{"k":1}'; ); [ "$(count)" = 1 ] && ok || fail 'fallback: config.json BATON_COLLECT=1 should emit'

echo "test-collection-gating: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
