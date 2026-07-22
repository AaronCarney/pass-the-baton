#!/bin/bash
# baton-dashboard.sh - drive the /baton skill.
# Usage:
#   baton-dashboard.sh show
#   baton-dashboard.sh set key=value [key2=value2 ...]
#   baton-dashboard.sh  (no args: same as `show`)

set -u

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/baton"
CFG="$CFG_DIR/config.json"
mkdir -p "$CFG_DIR"
[ -f "$CFG" ] || echo '{}' > "$CFG"

# Shared env-var > config.json > default precedence helper.
# shellcheck source=../lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/config.sh"

# TTL default helpers (workstream_ttl_seconds/tracking_ttl_seconds/tmp_ttl_minutes)
# so the dashboard shows the SAME defaults the cron sweep actually uses.
# shellcheck source=../.claude/hooks/lib/workstream-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/hooks/lib/workstream-lib.sh"

KNOWN_TEMPLATES="free task factory"

# Bracketed effective-source tag for a key row: [env]|[config]|[default].
_src() { printf '[%s]' "$(_cfg::source "$1" "${2:-$1}")"; }

_show() {
  local template tv
  template=$(jq -r '.template // "free"' "$CFG" 2>/dev/null)
  tv=$(jq -r --arg t "$template" '.per_template[$t].template_version // 1' "$CFG")
  echo "baton config ($CFG)"
  printf '\n[Existing]\n'
  printf '  %-32s %-40s %s\n' 'template:'              "$template" '[config-only]'
  printf '  %-32s %-40s %s\n' 'threshold_pct:'         "$(_cfg::get BATON_PCT_THRESHOLD "$BATON_DEFAULT_PCT_THRESHOLD" threshold_pct)" "$(_src BATON_PCT_THRESHOLD threshold_pct)"
  printf '  %-32s %-40s %s\n' 'display_name:'          "$(_cfg::get BATON_DISPLAY_NAME '' display_name)" "$(_src BATON_DISPLAY_NAME display_name)"
  printf '  %-32s %-40s %s\n' 'max_terminals_per_workstream:' "$(_cfg::get BATON_MAX_TERMINALS_PER_WORKSTREAM "$BATON_DEFAULT_MAX_TERMINALS" max_terminals_per_workstream)" "$(_src BATON_MAX_TERMINALS_PER_WORKSTREAM max_terminals_per_workstream)"
  printf '  %-32s %-40s %s\n' 'templates_dir:'         "$(jq -r '.templates_dir // empty' "$CFG" 2>/dev/null)" '[config-only]'
  printf '  %-32s %-40s %s\n' 'project_context_file:'  "$(jq -r '.project_context_file // empty' "$CFG" 2>/dev/null)" '[config-only]'
  printf '\n[Paths]\n'
  printf '  %-32s %-40s %s\n' 'BATON_DIR:'           "${BATON_DIR:-$PWD/.baton}" '[env-only by design]'
  printf '  %-32s %-40s %s\n' 'BATON_PROGRESS_DIR:'  "$(_cfg::get BATON_PROGRESS_DIR "$PWD/.baton/progress")" "$(_src BATON_PROGRESS_DIR)"
  printf '  %-32s %-40s %s\n' 'BATON_ARCHIVE_DIR:'   "$(_cfg::get BATON_ARCHIVE_DIR "$HOME/.local/share/baton")" "$(_src BATON_ARCHIVE_DIR)"
  printf '  %-32s %-40s %s\n' 'BATON_PROJECT_DIR:'   "${BATON_PROJECT_DIR:-$PWD}" '[env-only by design]'
  printf '\n[TTLs]\n'
  printf '  %-32s %-40s %s\n' 'BATON_WORKSTREAM_TTL_DAYS:' "$(( $(workstream_ttl_seconds) / 86400 ))" "$(_src BATON_WORKSTREAM_TTL_DAYS)"
  printf '  %-32s %-40s %s\n' 'BATON_TRACKING_TTL_DAYS:'   "$(( $(tracking_ttl_seconds) / 86400 ))" "$(_src BATON_TRACKING_TTL_DAYS)"
  printf '  %-32s %-40s %s\n' 'BATON_TMP_TTL_HOURS:'       "$(( $(tmp_ttl_minutes) / 60 ))" "$(_src BATON_TMP_TTL_HOURS)"
  printf '\n[Opt-ins]\n'
  printf '  %-32s %-40s %s\n' 'BATON_COLLECT:'            "$(_cfg::get BATON_COLLECT 0)" "$(_src BATON_COLLECT)"
  printf '  %-32s %-40s %s\n' 'BATON_TIMING:'             "$(_cfg::get BATON_TIMING 0)" "$(_src BATON_TIMING)"
  printf '  %-32s %-40s %s\n' 'BATON_OUTCOME_PROXIES:'    "$(_cfg::get BATON_OUTCOME_PROXIES 0)" "$(_src BATON_OUTCOME_PROXIES)"
  printf '  %-32s %-40s %s\n' 'BATON_PREWARM:'            "$(_cfg::get BATON_PREWARM 0)" "$(_src BATON_PREWARM)"
  printf '  %-32s %-40s %s\n' 'BATON_EVENT_LOG_DISABLE:'  "$(_cfg::get BATON_EVENT_LOG_DISABLE 0)" "$(_src BATON_EVENT_LOG_DISABLE)"
  # Resolver, NOT a bare _cfg::get on the raw key: the latter would skip the legacy
  # BATON_AUTO_CONTINUE=1 -> tmux fallback and print `off [default]` while
  # checkpoint-write-trigger.sh arms the tmux injector - the exact disagreement
  # lib/config.sh:6-10 forbids.
  printf '  %-32s %-40s %s\n' 'auto_continue_mode:' "$(_cfg::auto_continue_mode)" "$(_src BATON_AUTO_CONTINUE_MODE auto_continue_mode)"
  printf '  %-32s %-40s %s\n' 'launch_alias:'       "$(jq -r '.launch_alias // empty' "$CFG" 2>/dev/null)" '[config-only]'
  printf '  %-32s %-40s %s\n' 'BATON_AUTO_CONTINUE_NUDGE:' "$(_cfg::get BATON_AUTO_CONTINUE_NUDGE "$BATON_DEFAULT_AUTO_CONTINUE_NUDGE")" "$(_src BATON_AUTO_CONTINUE_NUDGE)"
  printf '  %-32s %-40s %s\n' 'BATON_AUTO_CONTINUE_LOG:'   "$(_cfg::get BATON_AUTO_CONTINUE_LOG "${TMPDIR:-/tmp}/baton-auto-continue.log")" "$(_src BATON_AUTO_CONTINUE_LOG)"
  printf '  %-32s %-40s %s\n' 'BATON_AUTO_CONTINUE_BIN:'   "$(_cfg::get BATON_AUTO_CONTINUE_BIN "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/baton-auto-continue.sh")" "$(_src BATON_AUTO_CONTINUE_BIN)"
  printf '\n[Event-log]\n'
  printf '  %-32s %-40s %s\n' 'BATON_EVENT_LOG:'      "$(_cfg::get BATON_EVENT_LOG "${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl")" "$(_src BATON_EVENT_LOG)"
  printf '  %-32s %-40s %s\n' 'BATON_OTEL_EXPORT:'    "$(_cfg::get BATON_OTEL_EXPORT '')" "$(_src BATON_OTEL_EXPORT)"
  printf '\n[Cost-model]\n'
  printf '  %-32s %-40s %s\n' 'BATON_COST_MODEL:'     "$(_cfg::get BATON_COST_MODEL claude-sonnet-4-6)" "$(_src BATON_COST_MODEL)"
  printf '  %-32s %-40s %s\n' 'BATON_SUMMARY_MODEL:'  "$(_cfg::get BATON_SUMMARY_MODEL '')" "$(_src BATON_SUMMARY_MODEL)"
  printf '  %-32s %-40s %s\n' 'BATON_TOKEN_RATIOS:'   "$(_cfg::get BATON_TOKEN_RATIOS "$HOME/.config/baton/token-ratios.sh")" "$(_src BATON_TOKEN_RATIOS)"
  printf '\n[Statusline]\n'
  printf '  %-32s %-40s %s\n' 'BATON_STATUSLINE_COLOR_MODE:' "$(_cfg::get BATON_STATUSLINE_COLOR_MODE off)" "$(_src BATON_STATUSLINE_COLOR_MODE)"
  printf '\nActive template (%s):\n' "$template"
  printf '  %-32s %s\n' 'template_version:' "$tv"
  printf '\nSource tag per row reflects how the actual runtime consumer reads the key:\n'
  printf '  [env]/[config]/[default]  the consumer routes through _cfg::get, precedence\n'
  printf '     env var > config.json > default; the tag names the layer in effect now.\n'
  printf '  [config-only]  the consumer reads config.json directly and ignores the env\n'
  printf '     var (template, templates_dir, project_context_file); set it via this\n'
  printf '     dashboard, exporting the env var has no runtime effect.\n'
  printf '  [env-only by design]  BATON_DIR/BATON_PROJECT_DIR locate the state dir before\n'
  printf '     config is read; setting them here has no effect, export the env var.\n'
  printf 'For an [env]-tagged key a dashboard set writes config.json but will not take\n'
  printf 'until you unset the shadowing env var. threshold_pct moves the actual checkpoint\n'
  printf 'trigger (bounds 1-99, else %s) and is reported unchanged in the telemetry\n' "$BATON_DEFAULT_PCT_THRESHOLD"
  printf 'threshold field.\n'
  printf 'auto_continue_mode shows tmux [default] when only the legacy BATON_AUTO_CONTINUE=1\n'
  printf 'is set: the mode IS defaulted, and the legacy flag is what that default resolves to.\n'
}

_set_one() {
  local kv="$1"
  local key="${kv%%=*}"
  local value="${kv#*=}"

  case "$key" in
    template)
      local found=0
      echo "$KNOWN_TEMPLATES" | grep -qw "$value" && found=1
      if [ "$found" = "0" ]; then
        local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
        [ -f "$cfg_root/baton/templates/${value}.md" ] && found=1
      fi
      if [ "$found" = "0" ]; then
        local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
        echo "Error: unknown template '$value'. Known: $KNOWN_TEMPLATES. (Custom templates: install to $cfg_root/baton/templates/${value}.md first.)" >&2
        return 1
      fi
      # M6: refuse a template switch only while THIS terminal's OWN LIVE checkpoint
      # is in flight. This used to glob /tmp/baton-pending-* unscoped, so any live
      # checkpoint in any project on the machine blocked a template switch. The
      # guard keys on session_id, which is STABLE across `claude --resume`
      # (term_hash is NOT: CLAUDE_TERMINAL_ID is unset by Claude Code, so it
      # degrades to md5(user:tty) and a resume in another window gets a new hash).
      # session-start.sh:207 writes an UNCONDITIONAL per-terminal map
      # /tmp/claude-parent-sid-<term_hash> -> session_id, refreshed on EVERY
      # SessionStart including source=resume, so the dashboard resolves its own
      # session_id from its own term_hash (term_hash() is in scope via
      # workstream-lib.sh at :22) and self-heals across resume. It then checks ONLY
      # /tmp/baton-pending-<its session_id>; a live flag in any other session no
      # longer blocks. The statusline rewrites /tmp/claude-context-pct-<sid> every
      # turn and cleanup-on-exit removes both files together, so a pending flag
      # whose pct sibling is missing or older than the liveness window
      # (mode-dependent; see below) belongs to a session that is gone.
      # KNOWN FAIL-OPEN: when _my_sid is empty the guard ALLOWS the switch, which
      # under-blocks one rare edge - a single continuous session older than the /tmp
      # TTL (no /clear|/compact|/resume, which each rewrite :207 and reset the mtime)
      # whose parent-sid map was swept by cleanup-cron (mtime pinned at session start)
      # while a live pending flag survives; fail-OPEN toward the owner's less-blocking
      # goal and advisory (no data loss). Durable fix (refresh the map mtime when the
      # pending flag is written, in context-checkpoint.sh) is the checkpoint WRITE path
      # and is DEFERRED. See docs/research/2026-07-20-terminal-scoping-resume-identity.md.
      _pending_live=0
      _th=$(term_hash 2>/dev/null || echo "")
      _my_sid=""
      if [ -n "$_th" ] && [ -e "/tmp/claude-parent-sid-${_th}" ]; then
        _my_sid=$(tr -d '[:space:]' < "/tmp/claude-parent-sid-${_th}" 2>/dev/null)
      fi
      # session_id is whitelisted [a-zA-Z0-9_-] at every origin; scrub defensively
      # since the map file lives in world-writable /tmp (empty -> fails open below).
      case "$_my_sid" in *[!a-zA-Z0-9_-]*) _my_sid="" ;; esac
      if [ -z "$_my_sid" ]; then
        _pending_live=0  # this terminal owes nothing; allow the switch
      else
        _ttl_min=$(tmp_ttl_minutes 2>/dev/null || echo 1440)
        [[ "$_ttl_min" =~ ^[0-9]+$ ]] || _ttl_min=1440
        # The liveness window depends on the checkpoint mode, read from THIS
        # dashboard's own global config - the same config this switch edits. Under
        # auto-continue (tmux/relaunch) the session writes the checkpoint itself, so
        # PENDING clears within a turn or two: a pct sibling older than a few minutes
        # means the session is gone. Under manual mode (off) the session parks at the
        # checkpoint and waits for the user, who may be away for hours, so a
        # legitimately-owed flag must be trusted until the /tmp TTL sweep would reap
        # it anyway. A single fixed window mis-judges one mode or the other: a short
        # window calls a live-but-idle manual session dead; the full TTL lets a
        # crashed auto-continue session block switches for a day. _cfg::auto_continue_mode
        # is already in scope here (the dashboard calls it at :60).
        if [ "$(_cfg::auto_continue_mode 2>/dev/null || echo off)" != "off" ]; then
          _live_min="${BATON_PENDING_LIVE_MIN:-15}"
          [[ "$_live_min" =~ ^[0-9]+$ ]] || _live_min=15
        else
          _live_min="$_ttl_min"
        fi
        _pf="/tmp/baton-pending-${_my_sid}"
        _pct_file="/tmp/claude-context-pct-${_my_sid}"
        if [ -e "$_pf" ] && [ -e "$_pct_file" ] && \
           [ -n "$(find "$_pct_file" -maxdepth 0 -mmin -"$_live_min" 2>/dev/null)" ]; then
          _pending_live=1
        fi
      fi
      if [ "$_pending_live" = "1" ]; then
        echo "Error: cannot switch template while a checkpoint is in flight (PENDING). Wait for the next progress write to clear, then retry." >&2
        return 1
      fi
      ;;
    threshold_pct)
      [[ "$value" =~ ^[0-9]+$ ]] || { echo "Error: threshold_pct must be an integer" >&2; return 1; }
      if [ "$value" -lt 1 ] || [ "$value" -gt 99 ]; then
        echo "Error: threshold_pct out of range - must be 1-99" >&2
        return 1
      fi
      ;;
    display_name|templates_dir|project_context_file)
      ;;  # free-form string, no validation
    BATON_DIR|BATON_PROGRESS_DIR|BATON_ARCHIVE_DIR|BATON_PROJECT_DIR|\
    BATON_EVENT_LOG|BATON_OTEL_EXPORT|BATON_TOKEN_RATIOS)
      # free-form path; allow any non-empty string
      [ -n "$value" ] || { echo "Error: $key cannot be empty" >&2; return 1; }
      ;;
    BATON_WORKSTREAM_TTL_DAYS|BATON_TRACKING_TTL_DAYS|BATON_TMP_TTL_HOURS)
      [[ "$value" =~ ^[0-9]+$ ]] || { echo "Error: $key must be a non-negative integer" >&2; return 1; }
      ;;
    max_terminals_per_workstream)
      [[ "$value" =~ ^[0-9]+$ ]] || { echo "max_terminals_per_workstream must be a non-negative integer" >&2; return 1; }
      ;;
    BATON_TIMING|BATON_OUTCOME_PROXIES|BATON_PREWARM|BATON_EVENT_LOG_DISABLE|BATON_COLLECT)
      case "$value" in 0|1) ;; *) echo "Error: $key must be 0 or 1" >&2; return 1;; esac
      ;;
    BATON_COST_MODEL|BATON_SUMMARY_MODEL)
      # accept any string; full validation happens at cost.sh resolve time
      [ -n "$value" ] || { echo "Error: $key cannot be empty" >&2; return 1; }
      ;;
    BATON_STATUSLINE_COLOR_MODE)
      case "$value" in off|solid|bands) ;; *) echo "Error: $key color mode must be one of: off, solid, bands" >&2; return 1;; esac
      ;;
    BATON_AUTO_CONTINUE_NUDGE|BATON_AUTO_CONTINUE_LOG|BATON_AUTO_CONTINUE_BIN)
      [ -n "$value" ] || { echo "Error: $key cannot be empty" >&2; return 1; }
      ;;
    auto_continue_mode)
      case "$value" in off|tmux|relaunch) ;; *) echo "Error: $key must be one of: off, tmux, relaunch" >&2; return 1;; esac
      ;;
    launch_alias)
      # Validate the name via Task 1's lib, then persist AND rewrite the marker block in
      # each rc file. Pass the value as its own reclaim sentinel so re-setting the same
      # name does not trip the PATH-shadow check on an alias this dashboard installed.
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/shell-alias.sh"
      _prev_alias="$(_cfg::get launch_alias '')"
      alias_name_valid "$value" "$_prev_alias"; _rc_v=$?
      if [ "$_rc_v" -ne 0 ]; then
        case "$_rc_v" in
          1) echo "Error: launch_alias cannot be empty" >&2 ;;
          2) echo "Error: launch_alias must match [A-Za-z_][A-Za-z0-9_-]* (no spaces, slashes, or metacharacters)" >&2 ;;
          3) echo "Error: launch_alias '$value' is a shell builtin - pick another name" >&2 ;;
          4) echo "Error: launch_alias '$value' is a shell keyword - pick another name" >&2 ;;
          5) echo "Error: launch_alias '$value' already resolves on PATH (would shadow it) - pick another name" >&2 ;;
        esac
        return 1
      fi
      _cfg::set launch_alias "$value"
      _alias_target="bash $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/baton-run.sh"
      while IFS= read -r _rc; do
        alias_write "$value" "$_alias_target" "$_rc"
        echo "baton: launch alias '$value' written to $_rc" >&2
      done < <(alias_rc_files)
      unset _alias_target _rc _rc_v _prev_alias
      return 0
      ;;
    *)
      cat >&2 <<'EOF'
Error: unknown key. Valid keys:
  [Existing]   template, threshold_pct, display_name, templates_dir, project_context_file, max_terminals_per_workstream, auto_continue_mode, launch_alias
  [Paths]      BATON_DIR, BATON_PROGRESS_DIR, BATON_ARCHIVE_DIR, BATON_PROJECT_DIR
  [TTLs]       BATON_WORKSTREAM_TTL_DAYS, BATON_TRACKING_TTL_DAYS, BATON_TMP_TTL_HOURS
  [Opt-ins]    BATON_COLLECT, BATON_TIMING, BATON_OUTCOME_PROXIES, BATON_PREWARM, BATON_EVENT_LOG_DISABLE
  [Event-log]  BATON_EVENT_LOG, BATON_OTEL_EXPORT
  [Cost-model] BATON_COST_MODEL, BATON_SUMMARY_MODEL, BATON_TOKEN_RATIOS
  [Statusline] BATON_STATUSLINE_COLOR_MODE
  [Auto-cont]  BATON_AUTO_CONTINUE_NUDGE, BATON_AUTO_CONTINUE_LOG, BATON_AUTO_CONTINUE_BIN
EOF
      return 1
      ;;
  esac

  # Single config write path (E-C): the atomic flock+jq write now lives in lib/config.sh
  # so the dashboard and the threshold tuner cannot drift. threshold_pct is the one numeric key.
  case "$key" in
    threshold_pct|max_terminals_per_workstream) _cfg::set "$key" "$value" number ;;
    *)             _cfg::set "$key" "$value" ;;
  esac
}

case "${1:-}" in
  show|"")
    _show
    ;;
  set)
    shift
    [ $# -eq 0 ] && { echo "Usage: $0 set key=value [key2=value2 ...]" >&2; exit 1; }
    for kv in "$@"; do _set_one "$kv" || exit 1; done
    _show
    ;;
  *)
    echo "Usage: $0 [show|set key=value ...]" >&2
    exit 1
    ;;
esac
