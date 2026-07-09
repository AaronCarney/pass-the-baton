#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export XDG_CONFIG_HOME="$TMP_STATE/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
echo '{"threshold_pct":29}' > "$XDG_CONFIG_HOME/baton/config.json"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so emit-and-assert paths collect.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0
assert() { local label="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi; }

# Step-1 assertions (failing now, library does not exist)
# shellcheck disable=SC1091
source "$REPO_ROOT/.claude/hooks/lib/outcome-proxies.sh"
assert 'consent_on function defined' "declare -f outcome_proxies::consent_on >/dev/null"
assert 'emit_event function defined' "declare -f outcome_proxies::emit_event >/dev/null"

# === consent off blocks emission ===
rm -f "$BATON_EVENT_LOG"
unset BATON_OUTCOME_PROXIES
out=$(outcome_proxies::emit_event test '{"x":1}' 2>&1)
rc=$?
assert 'consent off → rc=0 (silent)' "[ $rc -eq 0 ]"
assert 'consent off → no log file or empty' "[ ! -s \"$BATON_EVENT_LOG\" ]"

# === consent on emits ===
rm -f "$BATON_EVENT_LOG"
export BATON_OUTCOME_PROXIES=1
outcome_proxies::emit_event code_execution '{"success":true,"runner":"pytest","exit_code":0}'
assert 'consent on → log has 1 line' "[ $(wc -l < "$BATON_EVENT_LOG") -eq 1 ]"
assert 'event=outcome_proxy' "jq -e '.event == \"outcome_proxy\"' \"$BATON_EVENT_LOG\" >/dev/null"
assert 'data.subkind=code_execution' "jq -e '.data.subkind == \"code_execution\"' \"$BATON_EVENT_LOG\" >/dev/null"
assert 'data.threshold stamped (29)' "jq -e '.data.threshold == 29' \"$BATON_EVENT_LOG\" >/dev/null"
assert 'data.success=true' "jq -e '.data.success == true' \"$BATON_EVENT_LOG\" >/dev/null"
assert 'data.runner=pytest' "jq -e '.data.runner == \"pytest\"' \"$BATON_EVENT_LOG\" >/dev/null"
unset BATON_OUTCOME_PROXIES

export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
set +e
outcome_proxies::emit_event broken '{not-json' 2>/dev/null
rc=$?
set -e
assert 'malformed payload → rc=1' "[ $rc -eq 1 ]"
assert 'malformed payload → no event emitted' "[ ! -s \"$BATON_EVENT_LOG\" ]"
unset BATON_OUTCOME_PROXIES

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
