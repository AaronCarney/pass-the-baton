#!/usr/bin/env bash
# Pure helpers - do not exec on source.

audit_metadata::_path() {
  printf '%s\n' "${BATON_AUDIT_METADATA:-${PWD}/.baton/audit-metadata.json}"
}

audit_metadata::read() {
  local p; p="$(audit_metadata::_path)"
  if [ ! -f "$p" ]; then
    printf '{}\n'
    return 0
  fi
  cat "$p"
}

audit_metadata::stamp_stage1() {
  local residual_json="$1" p; p="$(audit_metadata::_path)"
  local tmp; tmp="$(mktemp)"
  if [ -f "$p" ]; then
    jq --argjson r "$residual_json" '.stage1_residual_per_arm = $r' "$p" > "$tmp"
  else
    mkdir -p "$(dirname "$p")"
    jq -n --argjson r "$residual_json" '{stage1_residual_per_arm: $r}' > "$tmp"
  fi
  mv "$tmp" "$p"
}

audit_metadata::stamp_stage2() {
  local residual_json="$1" cache_break="${2:-false}" p; p="$(audit_metadata::_path)"
  local tmp; tmp="$(mktemp)"
  if [ -f "$p" ]; then
    jq --argjson r "$residual_json" --argjson cb "$cache_break" \
      '.stage2_residual_per_arm = $r | .cache_break_detected = $cb' "$p" > "$tmp"
  else
    mkdir -p "$(dirname "$p")"
    jq -n --argjson r "$residual_json" --argjson cb "$cache_break" \
      '{stage2_residual_per_arm: $r, cache_break_detected: $cb}' > "$tmp"
  fi
  mv "$tmp" "$p"
}

audit_metadata::is_stale() {
  local p; p="$(audit_metadata::_path)"
  [ ! -f "$p" ] && return 0
  local audit_date; audit_date="$(jq -r '.audit_date // ""' "$p")"
  [ -z "$audit_date" ] && return 0
  local audit_epoch now_epoch days_diff
  audit_epoch=$(date -u -d "$audit_date" +%s 2>/dev/null) || return 0
  now_epoch=$(date -u +%s)
  days_diff=$(( (now_epoch - audit_epoch) / 86400 ))
  [ "$days_diff" -gt 90 ] && return 0 || return 1
}
