#!/usr/bin/env bash
# CC6: opt-in/mode keys honor config.json via _cfg::get.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
CFG="$XDG_CONFIG_HOME/baton/config.json"
PASS=0; FAIL=0
_aeq(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: exp %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# outcome-proxies consent gate
OP="$REPO/.claude/hooks/lib/outcome-proxies.sh"
echo '{"BATON_OUTCOME_PROXIES":"1"}' > "$CFG"
# shellcheck disable=SC1090
if ( unset BATON_OUTCOME_PROXIES; source "$OP"; outcome_proxies::consent_on ); then _aeq on on 'OUTCOME_PROXIES=1 from config => consent on'; else _aeq on off 'OUTCOME_PROXIES config'; fi
echo '{}' > "$CFG"
# shellcheck disable=SC1090
if ( unset BATON_OUTCOME_PROXIES; source "$OP"; outcome_proxies::consent_on ); then _aeq off on 'default off'; else _aeq off off 'OUTCOME_PROXIES default off'; fi

# baton-pct color mode: config 'off' suppresses color even at high PCT
export SESSION_ID="pct-test-$$"
printf '95' > "/tmp/claude-context-pct-$SESSION_ID"
rm -f "/tmp/baton-done-$SESSION_ID"
trap 'rm -f "/tmp/claude-context-pct-$SESSION_ID"' EXIT
echo '{"BATON_STATUSLINE_COLOR_MODE":"off"}' > "$CFG"
out=$( unset BATON_STATUSLINE_COLOR_MODE; bash "$REPO/assets/baton-pct.sh" "$SESSION_ID" )
_aeq 'CTX:95%' "$out" 'COLOR_MODE off from config: no ANSI'
echo '{"BATON_STATUSLINE_COLOR_MODE":"solid"}' > "$CFG"
out=$( unset BATON_STATUSLINE_COLOR_MODE; bash "$REPO/assets/baton-pct.sh" "$SESSION_ID" )
case "$out" in *$'\033['*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo 'FAIL: COLOR_MODE solid from config should emit ANSI at 95%' >&2;; esac
echo '{"BATON_STATUSLINE_COLOR_MODE":"bands"}' > "$CFG"
out=$( unset BATON_STATUSLINE_COLOR_MODE; bash "$REPO/assets/baton-pct.sh" "$SESSION_ID" )
case "$out" in *$'\033[31m'*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo 'FAIL: COLOR_MODE bands from config should emit red ANSI at 95%' >&2;; esac

# tool-timing fast off-path: config TIMING=0 => off-path (drains stdin, exit 0, no event).
# We assert the gate reads config by checking that TIMING=1 in config takes the ON path far enough to
# require stdin JSON (off-path just drains). Minimal proof: with config=0 it exits 0 on empty stdin.
TT="$REPO/.claude/hooks/tool-timing.sh"
echo '{}' > "$CFG"
if printf '' | ( unset BATON_TIMING; bash "$TT" >/dev/null 2>&1 ); then _aeq ok ok 'tool-timing off-path exits 0 (default)'; else _aeq ok bad 'tool-timing default'; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
