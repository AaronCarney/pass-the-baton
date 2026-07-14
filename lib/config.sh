#!/usr/bin/env bash
# lib/config.sh - env-var > config.json > default precedence for BATON_* keys.
# Sourced by tools and (progressively) hooks. CC6: additive - does not change any
# existing hook's read path until that hook is migrated.

# Canonical compiled default for the checkpoint trigger threshold (context-fill %).
# SINGLE SOURCE OF TRUTH: checkpoint_threshold, the context-checkpoint faithful
# fallback, the dashboard default arg, and every "current default" display read
# this one constant, so a shown value can never disagree with the gate. Owner-set
# to 20 (directive 2026-07-11); the user-facing knob stays BATON_PCT_THRESHOLD.
BATON_DEFAULT_PCT_THRESHOLD=20

# Co-tenancy cap: max concurrent terminals per workstream. 0 = unlimited (opt-in,
# off by default so it is non-breaking). cap=1 documents solo-only.
BATON_DEFAULT_MAX_TERMINALS=0

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
  # 1. env var wins. Indirect expansion (not printenv) so a NON-exported shell
  # var is honored too - restores the pre-CC6 `${VAR:-}` contract that callers
  # like cleanup-cron.sh (non-exported BATON_ARCHIVE_DIR) depend on.
  local env_val
  env_val="${!key:-}"
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

_cfg::source() {
  # Usage: _cfg::source ENV_KEY [config_key]
  # Reports WHICH layer _cfg::get would resolve from: env|config|default.
  # Same precedence and null/malformed handling as _cfg::get, value discarded.
  local key="$1"
  local cfg_key="${2:-$key}"
  local env_val
  env_val="${!key:-}"
  if [ -n "$env_val" ]; then
    printf 'env'
    return 0
  fi
  local cfg
  cfg="$(_cfg::path)"
  if [ -f "$cfg" ]; then
    local json_val
    json_val="$(jq -r --arg k "$cfg_key" '.[$k] // empty' "$cfg" 2>/dev/null || true)"
    if [ -n "$json_val" ] && [ "$json_val" != 'null' ]; then
      printf 'config'
      return 0
    fi
  fi
  printf 'default'
}

_cfg::set() {
  # Usage: _cfg::set KEY VALUE [is_number]
  # Atomically write .[KEY]=VALUE into config.json (env layer is NOT touched - this only
  # persists the config.json layer that _cfg::get reads second). When is_number is non-empty
  # the value is written as a JSON number (--argjson); otherwise as a JSON string (--arg).
  # Self-contained: resolves its own path, seeds a missing dir/file, atomic mktemp+mv under flock.
  # The sole config WRITE path (mirrors _cfg::get as the sole READ path) so the dashboard and the
  # threshold tuner cannot drift. Round-trips with _cfg::get (use the persisted config_key as KEY,
  # e.g. _cfg::set threshold_pct 30 number  <->  _cfg::get BATON_PCT_THRESHOLD 20 threshold_pct).
  local key="$1" value="$2" is_number="${3:-}"
  local cfg; cfg="$(_cfg::path)"
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || printf '{}' > "$cfg"
  local tmp; tmp=$(mktemp -p "$(dirname "$cfg")")
  exec 9>"${cfg}.lock"
  flock 9
  if [ -n "$is_number" ]; then
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  else
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  fi
  local rc=$?
  rm -f "$tmp"
  flock -u 9
  exec 9>&-
  return $rc
}

export -f _cfg::get 2>/dev/null || true
export -f _cfg::set 2>/dev/null || true
export -f _cfg::source 2>/dev/null || true
# Export the dependency too: _cfg::get calls _cfg::path internally, so a child
# process inheriting the exported _cfg::get must also inherit _cfg::path or it
# silently skips config.json. (CC6 code-review hardening.)
export -f _cfg::path 2>/dev/null || true
export BATON_DEFAULT_PCT_THRESHOLD 2>/dev/null || true
export BATON_DEFAULT_MAX_TERMINALS 2>/dev/null || true
