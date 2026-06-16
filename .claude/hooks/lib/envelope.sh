#!/bin/bash
# Envelope builder for hook events. CC2/CC8 contract.
# Sole writer of $BATON_EVENT_LOG. Sourced by hooks; not executed directly.

# Bumping schema_version requires editing this single constant.
schema_version=1

# Runtime defensive shim. tools/install.sh hard-fails when flock(1) is missing
# (it's in the required-cmd list), so a wired install always has flock. But if
# util-linux is removed after install (or PATH changes at runtime), the
# `( flock 9 ... ) 9>file` subshells in this file and the hooks that source it
# would silently drop atomicity - the inner flock would fail rc=non-zero, but
# the subshell would continue and the write would still happen unlocked.
# Provide a no-op shim + one-time stderr nag so the failure mode is visible
# and the hook still completes cleanly rather than mid-stream corrupting.
if ! command -v flock >/dev/null 2>&1; then
  flock() { :; }
  if [ -z "${_BATON_FLOCK_WARNED:-}" ]; then
    echo 'baton: flock(1) missing - events appended without locking. Install util-linux (macOS: brew install util-linux).' >&2
    _BATON_FLOCK_WARNED=1
    export _BATON_FLOCK_WARNED
  fi
fi

# E23/CC19: the collection gate needs _cfg::get (env > config.json > default).
# envelope.sh is sourced, so locate ourselves via BASH_SOURCE (precedent: lib/template-resolve.sh:48).
if ! declare -F _cfg::get >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../lib/config.sh" 2>/dev/null || true
fi
# Hard fallback: if config.sh was unavailable, define a FAITHFUL resolver (env >
# config.json > default) so the gate never errors AND the dashboard's config.json
# write is still honored. Mirrors lib/config.sh::_cfg::get exactly (key, default, cfg_key).
if ! declare -F _cfg::get >/dev/null 2>&1; then
  _cfg::get() {
    local v; v="$(printenv "$1" 2>/dev/null || true)"
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

envelope::_log_path() {
  if [ -n "${BATON_EVENT_LOG:-}" ]; then
    printf '%s' "$BATON_EVENT_LOG"
  else
    printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl"
  fi
}

envelope::_redact() {
  # CC8 redaction applied at envelope-build time, before size measurement.
  # Strip free-form text fields; collapse arg-bearing fields to a summary;
  # rewrite absolute-path string values to basename.
  jq -c '
    def basename_if_abs:
      if type == "string" and startswith("/")
      then (. | sub(".*/"; ""))
      else . end;
    def summarize_args:
      if type == "array" then
        ( (. | tostring) as $s
        | { arg_count: length,
            total_bytes: ($s | length),
            first64: ($s | .[0:64]) } )
      elif type == "object" then
        ( (. | tostring) as $s
        | { arg_count: (. | length),
            total_bytes: ($s | length),
            first64: ($s | .[0:64]) } )
      else
        ( (. | tostring) as $s
        | { arg_count: 1,
            total_bytes: ($s | length),
            first64: ($s | .[0:64]) } )
      end;
    walk(
      if type == "object" then
        with_entries(
          if .key | IN("prompt","completion","content","text","message","messages","response")
          then empty
          elif .key | IN("args","arguments","tool_input")
          then .value |= summarize_args
          else .value |= basename_if_abs
          end
        )
      else . end
    )
  '
}

# Resolve the open arc owned by THIS terminal. Prints "slug<TAB>method" or nothing.
# Terminal is taken from CLAUDE_TERMINAL_ID only: the hostname-PPID fallback used by
# tools/project.sh would not match here (the hook PPID differs from the marker's), so
# without the env var we deliberately emit no stamp. Keys on terminal_id (NOT session),
# so multiple sessions sharing the terminal accrue to one envelope.
envelope::_active_arc() {
  local term="${CLAUDE_TERMINAL_ID:-}"
  [ -z "$term" ] && return 0
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/baton/projects"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if jq -e --arg t "$term" '.terminal_id == $t and (has("ended_at") | not)' "$f" >/dev/null 2>&1; then
      jq -r '[.slug, (.method // "")] | @tsv' "$f"
      return 0
    fi
  done
  return 0
}

envelope::emit() {
  # Hard kill-switch - highest precedence (unchanged).
  [ "${BATON_EVENT_LOG_DISABLE:-0}" = "1" ] && return 0

  # E23/CC19 off-by-default gate: collect only when an arc is open OR the global
  # collect flag is enabled. Resolve the arc ONCE here and reuse it for the stamp below.
  local _arc; _arc="$(envelope::_active_arc)"
  if [ -z "$_arc" ] && [ "$(_cfg::get BATON_COLLECT 0)" != "1" ]; then
    return 0
  fi

  local event_name="${1:-unknown}"
  local data_json="${2:-{\}}"
  local log_path; log_path=$(envelope::_log_path)

  data_json=$(printf '%s' "$data_json" | envelope::_redact)

  # Arc stamp: terminal/session-scoped (CC17). Adds project_slug + method when an arc is open.
  # _arc was resolved ONCE at the top (gate); reused here to avoid a second projects-dir scan.
  if [ -n "$_arc" ]; then
    local _aslug="${_arc%%$'\t'*}" _amethod="${_arc#*$'\t'}"
    [ "$_amethod" = "$_arc" ] && _amethod=''   # defensive-only: @tsv of two fields ALWAYS yields a tab, so this guards only a hypothetical single-field resolver output
    data_json="$(printf '%s' "$data_json" | jq -c --arg s "$_aslug" --arg m "$_amethod" '. + {project_slug:$s, method:$m}')"
  fi

  mkdir -p "$(dirname "$log_path")"
  if [ ! -e "$log_path" ]; then
    (umask 0177; : >> "$log_path")
  fi
  chmod 0600 "$log_path" 2>/dev/null || true

  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local line
  line=$(jq -cn \
    --argjson sv "$schema_version" \
    --arg ev "$event_name" \
    --arg ts "$ts" \
    --argjson data "$data_json" \
    '{schema_version:$sv, event:$ev, ts:$ts, data:$data}')

  local bytes=$(( ${#line} + 1 ))   # include trailing newline

  if [ "$bytes" -gt 4096 ]; then
    local trunc
    trunc=$(jq -cn \
      --argjson sv "$schema_version" \
      --arg ev "$event_name" \
      --arg ts "$ts" \
      --argjson ob "$bytes" \
      '{schema_version:$sv, event:$ev, ts:$ts, truncated:true, original_bytes:$ob}')
    printf '%s\n' "$trunc" >> "$log_path"
    printf 'baton: event truncated (%d bytes > 4096)\n' "$bytes" >&2
    return 1
  fi

  # Torn-line safety: if file ends without newline, prepend one to our line so
  # the prior (torn) record stays untouched but our line parses cleanly.
  local prefix=''
  if [ -s "$log_path" ]; then
    local tail_byte
    tail_byte=$(tail -c1 "$log_path" | od -An -tx1 | tr -d ' \n')
    if [ "$tail_byte" != '0a' ]; then
      prefix=$'\n'
    fi
  fi

  if [ "$bytes" -gt 512 ]; then
    (
      flock 9
      printf '%s%s\n' "$prefix" "$line" >> "$log_path"
    ) 9>"$log_path.lock"
  else
    printf '%s%s\n' "$prefix" "$line" >> "$log_path"
  fi
  return 0
}
