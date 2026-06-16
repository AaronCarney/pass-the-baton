#!/usr/bin/env bash
# lib/config.sh - env-var > config.json > default precedence for BATON_* keys.
# Sourced by tools and (progressively) hooks. CC6: additive - does not change any
# existing hook's read path until that hook is migrated.

_cfg::path() {
  printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json"
}

_cfg::get() {
  # Usage: _cfg::get ENV_KEY [default] [config_key]
  # ENV_KEY names the env var; config_key (when given) names the JSON key in
  # config.json - needed for legacy keys whose env name (BATON_PCT_THRESHOLD)
  # differs from their persisted config key (threshold_pct). Defaults to ENV_KEY.
  local key="$1"
  local default="${2:-}"
  local cfg_key="${3:-$key}"
  # 1. env var wins.
  local env_val
  env_val="$(printenv "$key" 2>/dev/null || true)"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return 0
  fi
  # 2. config.json next.
  local cfg
  cfg="$(_cfg::path)"
  if [ -f "$cfg" ]; then
    local json_val
    json_val="$(jq -r --arg k "$cfg_key" '.[$k] // empty' "$cfg" 2>/dev/null || true)"
    if [ -n "$json_val" ] && [ "$json_val" != 'null' ]; then
      printf '%s' "$json_val"
      return 0
    fi
  fi
  # 3. default.
  printf '%s' "$default"
}

export -f _cfg::get 2>/dev/null || true
