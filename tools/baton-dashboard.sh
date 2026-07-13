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
  printf '  %-32s %-40s %s\n' 'templates_dir:'         "$(jq -r '.templates_dir // empty' "$CFG" 2>/dev/null)" '[config-only]'
  printf '  %-32s %-40s %s\n' 'project_context_file:'  "$(jq -r '.project_context_file // empty' "$CFG" 2>/dev/null)" '[config-only]'
  printf '\n[Paths]\n'
  printf '  %-32s %-40s %s\n' 'BATON_DIR:'           "$(_cfg::get BATON_DIR "$PWD/.baton")" '[env-only by design]'
  printf '  %-32s %-40s %s\n' 'BATON_PROGRESS_DIR:'  "$(_cfg::get BATON_PROGRESS_DIR "$PWD/.baton/progress")" "$(_src BATON_PROGRESS_DIR)"
  printf '  %-32s %-40s %s\n' 'BATON_ARCHIVE_DIR:'   "$(_cfg::get BATON_ARCHIVE_DIR "$HOME/.local/share/baton")" "$(_src BATON_ARCHIVE_DIR)"
  printf '  %-32s %-40s %s\n' 'BATON_PROJECT_DIR:'   "$(_cfg::get BATON_PROJECT_DIR "$PWD")" '[env-only by design]'
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
      # M6: refuse template switch while a checkpoint is in flight (PENDING flag set).
      if ls /tmp/baton-pending-* >/dev/null 2>&1; then
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
    *)
      cat >&2 <<'EOF'
Error: unknown key. Valid keys:
  [Existing]   template, threshold_pct, display_name, templates_dir, project_context_file
  [Paths]      BATON_DIR, BATON_PROGRESS_DIR, BATON_ARCHIVE_DIR, BATON_PROJECT_DIR
  [TTLs]       BATON_WORKSTREAM_TTL_DAYS, BATON_TRACKING_TTL_DAYS, BATON_TMP_TTL_HOURS
  [Opt-ins]    BATON_COLLECT, BATON_TIMING, BATON_OUTCOME_PROXIES, BATON_PREWARM, BATON_EVENT_LOG_DISABLE
  [Event-log]  BATON_EVENT_LOG, BATON_OTEL_EXPORT
  [Cost-model] BATON_COST_MODEL, BATON_SUMMARY_MODEL, BATON_TOKEN_RATIOS
  [Statusline] BATON_STATUSLINE_COLOR_MODE
EOF
      return 1
      ;;
  esac

  # Single config write path (E-C): the atomic flock+jq write now lives in lib/config.sh
  # so the dashboard and the threshold tuner cannot drift. threshold_pct is the one numeric key.
  case "$key" in
    threshold_pct) _cfg::set "$key" "$value" number ;;
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
