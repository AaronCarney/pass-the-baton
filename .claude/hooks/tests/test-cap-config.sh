#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/lib/config.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
TMP=$(mktemp -d); export XDG_CONFIG_HOME="$TMP/cfg"
DASH="$REPO/tools/baton-dashboard.sh"

# default when unset
unset BATON_MAX_TERMINALS_PER_WORKSTREAM
assert "default-0" "[ \"\$(_cfg::get BATON_MAX_TERMINALS_PER_WORKSTREAM \"\$BATON_DEFAULT_MAX_TERMINALS\" max_terminals_per_workstream)\" = 0 ]"
# dashboard set persists as a JSON NUMBER
bash "$DASH" set max_terminals_per_workstream=2 >/dev/null
assert "persisted-number" "[ \"\$(jq -r '.max_terminals_per_workstream' \"$XDG_CONFIG_HOME/baton/config.json\")\" = 2 ]"
assert "get-reads-it" "[ \"\$(_cfg::get BATON_MAX_TERMINALS_PER_WORKSTREAM 0 max_terminals_per_workstream)\" = 2 ]"
# show displays it
assert "show-displays" "bash \"$DASH\" show | grep -qi max_terminals_per_workstream"
# invalid rejected (rc!=0), config unchanged
set +e; bash "$DASH" set max_terminals_per_workstream=abc >/dev/null 2>&1; rc=$?; set -e 2>/dev/null || true
assert "reject-nonint" "[ $rc -ne 0 ]"
# env overrides config
assert "env-wins" "[ \"\$(BATON_MAX_TERMINALS_PER_WORKSTREAM=5 _cfg::get BATON_MAX_TERMINALS_PER_WORKSTREAM 0 max_terminals_per_workstream)\" = 5 ]"
rm -rf "$TMP"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
