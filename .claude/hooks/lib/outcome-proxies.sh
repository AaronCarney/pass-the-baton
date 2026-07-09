#!/usr/bin/env bash
# .claude/hooks/lib/outcome-proxies.sh - consent gate + emit shim for E16 proxy events.
# Sourced by .claude/hooks/outcome-proxy-*.sh and tools/outcome-proxy-*.sh.
# Sole gate for BATON_OUTCOME_PROXIES=1 (L0 D1 / L1 §E16 line 204).
set -u

_OP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_OP_DIR/envelope.sh"

# CC6: source the shared _cfg::get resolver (env > config.json > default).
# Self-contained: guard-source lib/config.sh; if unreachable, define a
# FAITHFUL inline fallback so a dashboard config.json write is still honored
# under plugin distribution. Precedent: .claude/hooks/lib/envelope.sh:26-48.
if ! declare -F _cfg::get >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/config.sh" 2>/dev/null || true
fi
if ! declare -F _cfg::get >/dev/null 2>&1; then
  _cfg::get() {
    local v; v="${!1:-}"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json"
    local ck="${3:-$1}"
    if [ -f "$cfg" ]; then
      v="$(jq -r --arg k "$ck" '.[$k] // empty' "$cfg" 2>/dev/null || true)"
      if [ -n "$v" ] && [ "$v" != 'null' ]; then printf '%s' "$v"; return 0; fi
    fi
    printf '%s' "${2:-}"
  }
fi

# E-C: active threshold stamp for self-describing outcome data. workstream-lib is functions-only.
if ! declare -F checkpoint_threshold >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_OP_DIR/workstream-lib.sh" 2>/dev/null || true
fi

outcome_proxies::consent_on() {
  [ "$(_cfg::get BATON_OUTCOME_PROXIES 0)" = "1" ]
}

outcome_proxies::emit_event() {
  outcome_proxies::consent_on || return 0
  local subkind="$1" payload="${2:-{\}}"
  local merged
  merged="$(printf '%s' "$payload" | jq -c --arg sk "$subkind" --argjson th "$(checkpoint_threshold)" '. + {subkind: $sk, threshold: $th}')" || return 1
  envelope::emit outcome_proxy "$merged"
}
