#!/usr/bin/env bash
# CC6: BATON_EVENT_LOG and BATON_EVENT_LOG_DISABLE honor config.json via _cfg::get.
# shellcheck disable=SC1090  # envelope.sh sourced via runtime $ENV_SH path
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
ENV_SH="$REPO/.claude/hooks/lib/envelope.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
export XDG_STATE_HOME="$TMP/state"
CFG="$XDG_CONFIG_HOME/baton/config.json"
PASS=0; FAIL=0
_aeq(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: exp %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# _log_path: config-set custom path is honored
echo '{"BATON_EVENT_LOG":"/x/custom.jsonl"}' > "$CFG"
_aeq '/x/custom.jsonl' "$( unset BATON_EVENT_LOG; source "$ENV_SH"; envelope::_log_path )" 'EVENT_LOG from config'
_aeq '/env/e.jsonl' "$( export BATON_EVENT_LOG=/env/e.jsonl; source "$ENV_SH"; envelope::_log_path )" 'EVENT_LOG env wins'
echo '{}' > "$CFG"
_aeq "$XDG_STATE_HOME/baton/hook-events.jsonl" "$( unset BATON_EVENT_LOG; source "$ENV_SH"; envelope::_log_path )" 'EVENT_LOG default = XDG state path'

# DISABLE kill-switch honored from config (emit must produce NO line)
echo '{"BATON_EVENT_LOG_DISABLE":"1","BATON_COLLECT":"1"}' > "$CFG"
LOG="$XDG_STATE_HOME/baton/hook-events.jsonl"
( unset BATON_EVENT_LOG_DISABLE BATON_COLLECT; export CLAUDE_TERMINAL_ID=ec-test-$$; source "$ENV_SH"; envelope::emit test_event '{"k":1}'; )
n=$([ -f "$LOG" ] && wc -l < "$LOG" || echo 0)
_aeq 0 "$n" 'EVENT_LOG_DISABLE=1 from config suppresses emit even with COLLECT=1'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
