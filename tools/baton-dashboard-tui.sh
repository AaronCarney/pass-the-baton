#!/bin/bash
# baton-dashboard-tui.sh - interactive /usage-style tabbed TUI for /baton.
# Sourced by baton-dashboard.sh; relies on its _show/_set_one and lib/config.sh
# already being in scope. Panes are pure render functions (testable without a
# TTY); _tui_loop is the thin input driver. No TTY -> caller falls back to _show.

_TUI_TABS=("Status" "Config" "History" "Workstreams")

_tui_supported() { [ -t 0 ] && [ -t 1 ]; }

# Resolve this terminal's session_id via the same parent-sid map _set_one uses.
_tui_sid() {
  local th sid=""
  th=$(term_hash 2>/dev/null || echo "")
  [ -n "$th" ] && [ -e "/tmp/claude-parent-sid-${th}" ] && \
    sid=$(tr -d '[:space:]' < "/tmp/claude-parent-sid-${th}" 2>/dev/null)
  case "$sid" in *[!a-zA-Z0-9_-]*) sid="" ;; esac
  printf '%s' "$sid"
}

# --- Pane: Status (read-only live monitor) --------------------------------
_tui_render_status() {
  local sid pct pending mode thr
  sid=$(_tui_sid)
  thr=$(_cfg::get BATON_PCT_THRESHOLD "$BATON_DEFAULT_PCT_THRESHOLD" threshold_pct)
  mode=$(_cfg::auto_continue_mode 2>/dev/null || echo off)
  if [ -n "$sid" ] && [ -e "/tmp/claude-context-pct-${sid}" ]; then
    pct=$(tr -d '[:space:]' < "/tmp/claude-context-pct-${sid}" 2>/dev/null)
  else
    pct="n/a"
  fi
  if [ -n "$sid" ] && [ -e "/tmp/baton-pending-${sid}" ]; then
    pending="PENDING (checkpoint owed)"
  else
    pending="clear"
  fi
  printf '  %-22s %s\n' 'Context fill:'      "${pct:-n/a}${pct:+%}"
  printf '  %-22s %s%%\n' 'Checkpoint at:'    "$thr"
  printf '  %-22s %s\n' 'Auto-continue:'      "$mode"
  printf '  %-22s %s\n' 'Checkpoint state:'   "$pending"
  printf '  %-22s %s\n' 'Session:'            "${sid:-unbound}"
}

# --- Pane: Config (the editor; parses _show as single source of truth) -----
# Read-only rows _set_one won't write (located before config exists).
_tui_key_readonly() { case "$1" in BATON_DIR|BATON_PROJECT_DIR|template_version) return 0;; *) return 1;; esac; }

# Emits "label<TAB>value<TAB>tag" per _show key row, excluding read-only rows, so
# label/value/tag never drift from _show. Editing delegates to _set_one.
_tui_config_rows() {
  local line label rest tag val
  while IFS= read -r line; do
    label="${line%%:*}"; rest="${line#*:}"
    _tui_key_readonly "$label" && continue
    rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim
    tag=""; val="$rest"
    case "$rest" in
      *\[*\]) tag="[${rest##*\[}"; tag="${tag%%\]*}]"; val="${rest%\[*}" ;;
    esac
    val="${val%"${val##*[![:space:]]}"}"       # rtrim
    printf '%s\t%s\t%s\n' "$label" "$val" "$tag"
  done < <(_show 2>/dev/null | sed -n 's/^  \([A-Za-z_][A-Za-z0-9_]*\):/\1:/p')
}

# Editable key at a cursor index (drives edit dispatch; same parse as render).
_tui_cfg_key_at() { _tui_config_rows | sed -n "$(( $1 + 1 ))p" | cut -f1; }
_tui_cfg_count()  { _tui_config_rows | wc -l | tr -d ' '; }

_tui_render_config() {
  local cursor="${1:-0}" i=0 mark label val tag row rest
  while IFS= read -r row; do
    label="${row%%$'\t'*}"; rest="${row#*$'\t'}"
    val="${rest%$'\t'*}"; tag="${rest##*$'\t'}"
    if [ "$i" = "$cursor" ]; then mark="> "; else mark="  "; fi
    printf '%s%-30s %-34s %s\n' "$mark" "$label" "${val:0:34}" "$tag"
    i=$((i+1))
  done < <(_tui_config_rows)
  printf '\n  [enter] edit selected   [up/down] move   %d keys\n' "$i"
}

# --- Pane: History (recent cost; wraps cost.sh, guarded) -------------------
_tui_render_history() {
  local out
  if ! command -v jq >/dev/null 2>&1; then printf '  jq unavailable.\n'; return; fi
  out=$(bash "$_TUI_DASH_DIR/cost.sh" --last 10 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    printf '  No cost data yet (needs event log / a completed session).\n'
    return
  fi
  printf '%s\n' "$out" | sed 's/^/  /' | head -30
}

# --- Pane: Workstreams (list tracked progress dirs) ------------------------
_tui_render_workstreams() {
  local pdir n=0
  pdir=$(_cfg::get BATON_PROGRESS_DIR "$PWD/.baton/progress")
  if [ ! -d "$pdir" ]; then printf '  No progress dir (%s).\n' "$pdir"; return; fi
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    printf '  %s\n' "$(basename "$f")"
    n=$((n+1))
  done < <(find "$pdir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
  [ "$n" = 0 ] && printf '  No tracked workstreams.\n'
}

_tui_render_pane() {
  case "$1" in
    0) _tui_render_status ;;
    1) _tui_render_config "${2:-0}" ;;
    2) _tui_render_history ;;
    3) _tui_render_workstreams ;;
  esac
}

_tui_render_frame() {
  local active="$1" cursor="${2:-0}" i=0 label bar=""
  for i in "${!_TUI_TABS[@]}"; do
    label="[$((i+1))]${_TUI_TABS[$i]}"
    if [ "$i" = "$active" ]; then bar+=" *${label}*"; else bar+="  ${label} "; fi
  done
  printf 'baton dashboard %s\n' "$bar"
  printf -- '%s\n' "------------------------------------------------------------------------"
  _tui_render_pane "$active" "$cursor"
  printf -- '%s\n' "------------------------------------------------------------------------"
  printf '1-4 switch   r refresh   q quit\n'
}

# --- Input driver ----------------------------------------------------------
_tui_loop() {
  local tab=0 cursor=0 key rest nkeys
  nkeys=$(_tui_cfg_count)
  while :; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    _tui_render_frame "$tab" "$cursor"
    IFS= read -rsn1 key || break
    case "$key" in
      q|Q) break ;;
      1) tab=0 ;; 2) tab=1 ;; 3) tab=2 ;; 4) tab=3 ;;
      r|R) : ;;
      $'\x1b')
        read -rsn2 -t 0.01 rest || rest=""
        case "$rest" in
          '[A') [ "$tab" = 1 ] && cursor=$(( cursor>0 ? cursor-1 : 0 )) ;;
          '[B') [ "$tab" = 1 ] && cursor=$(( cursor<nkeys-1 ? cursor+1 : nkeys-1 )) ;;
        esac ;;
      "")  # Enter: edit selected config key
        if [ "$tab" = 1 ]; then
          local k newval; k=$(_tui_cfg_key_at "$cursor")
          if [ -z "$k" ] || _tui_key_readonly "$k"; then continue; fi
          printf '\nNew value for %s: ' "$k"
          IFS= read -r newval || continue
          [ -z "$newval" ] && continue
          _set_one "${k}=${newval}" || { printf 'Press any key...'; read -rsn1 _; }
        fi ;;
    esac
  done
  clear 2>/dev/null || printf '\033[2J\033[H'
}

_tui_main() {
  _TUI_DASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if ! _tui_supported; then _show; return; fi
  _tui_loop
}
