#!/usr/bin/env bash
# .claude/hooks/lib/outcome-proxies.sh - consent gate + emit shim for E16 proxy events.
# Sourced by .claude/hooks/outcome-proxy-*.sh and tools/outcome-proxy-*.sh.
# Sole gate for BATON_OUTCOME_PROXIES=1 (L0 D1 / L1 §E16 line 204).
set -u

_OP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_OP_DIR/envelope.sh"

outcome_proxies::consent_on() {
  [ "${BATON_OUTCOME_PROXIES:-0}" = "1" ]
}

outcome_proxies::emit_event() {
  outcome_proxies::consent_on || return 0
  local subkind="$1" payload="${2:-{\}}"
  local merged
  merged="$(printf '%s' "$payload" | jq -c --arg sk "$subkind" '. + {subkind: $sk}')" || return 1
  envelope::emit outcome_proxy "$merged"
}
