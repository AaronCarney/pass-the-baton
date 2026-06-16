#!/usr/bin/env bash
# .claude/hooks/outcome-proxy-code-execution.sh - PostToolUse hook for the primary load-bearing proxy.
# Detects test-runner invocations and emits a numeric-only outcome_proxy event.
# Privacy (L0 D1 / L1 §E16 line 205): NO test output, NO command body - only success/runner/exit_code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/outcome-proxies.sh"

outcome_proxies::consent_on || exit 0

payload=$(cat)
[ -z "$payload" ] && exit 0

tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
exit_code=$(printf '%s' "$payload" | jq -r '.tool_response.exit_code // 0')
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
[ -z "$cmd" ] && exit 0

runner=""
case "$cmd" in
  *pytest*) runner="pytest" ;;
  *"npm test"*|*"npm run test"*) runner="npm-test" ;;
  *"cargo test"*) runner="cargo-test" ;;
  *"go test"*) runner="go-test" ;;
  *"make test"*) runner="make-test" ;;
  *bash*test*.sh*|*sh\ test*.sh*) runner="bash-test" ;;
  *) exit 0 ;;
esac

success="false"
[ "$exit_code" = "0" ] && success="true"

if [ -n "$session_id" ]; then
  proxy_payload=$(jq -cn \
    --argjson success "$success" \
    --arg runner "$runner" \
    --argjson exit_code "$exit_code" \
    --arg session_id "$session_id" \
    '{success: $success, runner: $runner, exit_code: $exit_code, session_id: $session_id}')
else
  proxy_payload=$(jq -cn \
    --argjson success "$success" \
    --arg runner "$runner" \
    --argjson exit_code "$exit_code" \
    '{success: $success, runner: $runner, exit_code: $exit_code}')
fi

outcome_proxies::emit_event code_execution "$proxy_payload" || true
exit 0
