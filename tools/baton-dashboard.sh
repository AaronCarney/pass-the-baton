#!/bin/bash
# baton-dashboard.sh - drive the /baton skill.
# Usage:
#   baton-dashboard.sh show
#   baton-dashboard.sh set key=value [key2=value2 ...]
#   baton-dashboard.sh  (interactive - currently identical to `show`)

set -u

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/baton"
CFG="$CFG_DIR/config.json"
mkdir -p "$CFG_DIR"
[ -f "$CFG" ] || echo '{}' > "$CFG"

# Shared env-var > config.json > default precedence helper.
# shellcheck source=../lib/config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/config.sh"

KNOWN_TEMPLATES="free task factory"

_show() {
  local template tv
  template=$(_cfg::get template free)
  tv=$(jq -r --arg t "$template" '.per_template[$t].template_version // 1' "$CFG")
  echo "baton config ($CFG)"
  printf '\n[Existing]\n'
  printf '  %-32s %s\n' 'template:'              "$template"
  printf '  %-32s %s\n' 'threshold_pct:'         "$(_cfg::get BATON_PCT_THRESHOLD 23 threshold_pct)"
  printf '  %-32s %s\n' 'display_name:'          "$(_cfg::get BATON_DISPLAY_NAME '' display_name)"
  printf '  %-32s %s\n' 'templates_dir:'         "$(_cfg::get BATON_TEMPLATES_DIR '' templates_dir)"
  printf '  %-32s %s\n' 'project_context_file:'  "$(_cfg::get BATON_PROJECT_CONTEXT_FILE '' project_context_file)"
  printf '\n[Paths]\n'
  printf '  %-32s %s\n' 'BATON_DIR:'           "$(_cfg::get BATON_DIR "$PWD/.baton")"
  printf '  %-32s %s\n' 'BATON_PROGRESS_DIR:'  "$(_cfg::get BATON_PROGRESS_DIR "$PWD/.baton/progress")"
  printf '  %-32s %s\n' 'BATON_ARCHIVE_DIR:'   "$(_cfg::get BATON_ARCHIVE_DIR "$HOME/.local/share/baton")"
  printf '  %-32s %s\n' 'BATON_PROJECT_DIR:'   "$(_cfg::get BATON_PROJECT_DIR "$PWD")"
  printf '\n[TTLs]\n'
  printf '  %-32s %s\n' 'BATON_WORKSTREAM_TTL_DAYS:' "$(_cfg::get BATON_WORKSTREAM_TTL_DAYS 30)"
  printf '  %-32s %s\n' 'BATON_TRACKING_TTL_DAYS:'   "$(_cfg::get BATON_TRACKING_TTL_DAYS 90)"
  printf '  %-32s %s\n' 'BATON_TMP_TTL_HOURS:'       "$(_cfg::get BATON_TMP_TTL_HOURS 48)"
  printf '\n[Opt-ins]\n'
  printf '  %-32s %s\n' 'BATON_COLLECT:'            "$(_cfg::get BATON_COLLECT 0)"
  printf '  %-32s %s\n' 'BATON_TIMING:'             "$(_cfg::get BATON_TIMING 0)"
  printf '  %-32s %s\n' 'BATON_OUTCOME_PROXIES:'    "$(_cfg::get BATON_OUTCOME_PROXIES 0)"
  printf '  %-32s %s\n' 'BATON_PREWARM:'            "$(_cfg::get BATON_PREWARM 0)"
  printf '  %-32s %s\n' 'BATON_EVENT_LOG_DISABLE:'  "$(_cfg::get BATON_EVENT_LOG_DISABLE 0)"
  printf '\n[Event-log]\n'
  printf '  %-32s %s\n' 'BATON_EVENT_LOG:'      "$(_cfg::get BATON_EVENT_LOG '')"
  printf '  %-32s %s\n' 'BATON_OTEL_EXPORT:'    "$(_cfg::get BATON_OTEL_EXPORT '')"
  printf '\n[Cost-model]\n'
  printf '  %-32s %s\n' 'BATON_COST_MODEL:'     "$(_cfg::get BATON_COST_MODEL claude-sonnet-4-6)"
  printf '  %-32s %s\n' 'BATON_SUMMARY_MODEL:'  "$(_cfg::get BATON_SUMMARY_MODEL claude-sonnet-4-6)"
  printf '  %-32s %s\n' 'BATON_TOKEN_RATIOS:'   "$(_cfg::get BATON_TOKEN_RATIOS '')"
  printf '\n[Statusline]\n'
  printf '  %-32s %s\n' 'BATON_STATUSLINE_COLOR_MODE:' "$(_cfg::get BATON_STATUSLINE_COLOR_MODE off)"
  printf '\nActive template (%s):\n' "$template"
  printf '  %-32s %s\n' 'template_version:' "$tv"
  printf '\nNote: template, templates_dir, project_context_file take effect from\n'
  printf 'config.json at runtime. Other BATON_* keys are read from the\n'
  printf 'environment by hooks (progressive config migration, CC6) - set the\n'
  printf 'matching env var to change runtime behavior until that hook migrates.\n'
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

  local tmp
  tmp=$(mktemp -p "$CFG_DIR")
  exec 9>"${CFG}.lock"
  flock 9
  case "$key" in
    threshold_pct)
      jq --argjson v "$value" '.threshold_pct = $v' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
      ;;
    *)
      jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
      ;;
  esac
  flock -u 9
  exec 9>&-
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
