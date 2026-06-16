#!/usr/bin/env bash
# lib/projects.sh - project-boundary state-file API + event emission.
# Sourced by tools/project.sh and .claude/hooks/lib/session-start-helpers.sh.
set -u

SCRIPT_DIR_PROJECTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_PROJECTS="$(cd "$SCRIPT_DIR_PROJECTS/.." && pwd)"

# Source envelope from its canonical location. envelope::emit is the sole writer
# of BATON_EVENT_LOG; it stamps top-level schema_version itself.
# shellcheck disable=SC1091
source "$REPO_ROOT_PROJECTS/.claude/hooks/lib/envelope.sh"

projects::state_dir() {
  local base="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
  printf '%s/projects' "$base"
}

projects::ensure_state_dir() {
  local dir; dir="$(projects::state_dir)"
  mkdir -p "$dir"
  touch "$dir/.keep"
}

projects::_atomic_write_json() {
  local content="$1" target="$2"
  local tmp; tmp="$(mktemp "${target}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$target"
  trap - RETURN
}

projects::mark_start_state() {
  local slug="$1" workstream="$2" description="${3:-}" terminal="${4:-}" method="${5:-}"
  projects::ensure_state_dir
  local dir; dir="$(projects::state_dir)"
  local target="$dir/${slug}.json"
  if [[ -f "$target" ]]; then
    echo "projects: state file already exists for slug=$slug ($target)" >&2
    return 2
  fi
  # CC17: at most one open arc per terminal. Only enforceable when we know the terminal.
  if [[ -n "$terminal" ]]; then
    local f
    for f in "$dir"/*.json; do
      [[ -e "$f" ]] || continue
      if jq -e --arg t "$terminal" '.terminal_id == $t and (has("ended_at") | not)' "$f" >/dev/null 2>&1; then
        echo "projects: terminal '$terminal' already has an open arc ($(jq -r .slug "$f")); mark-end it first" >&2
        return 2
      fi
    done
  fi
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local json
  json="$(jq -n \
    --arg slug "$slug" --arg started_at "$now" --arg workstream "$workstream" \
    --arg description "$description" --arg terminal_id "$terminal" --arg method "$method" \
    '{slug: $slug, started_at: $started_at, workstream: $workstream, description: $description, terminal_id: $terminal_id, method: $method, notes: []}')"
  projects::_atomic_write_json "$json" "$target"
}

projects::mark_end_state() {
  local slug="$1" status="$2" note="${3:-}"
  case "$status" in
    success|abandoned|paused) ;;
    *) echo "projects: status must be one of success|abandoned|paused (got: $status)" >&2; return 1 ;;
  esac
  projects::ensure_state_dir
  local target; target="$(projects::state_dir)/${slug}.json"
  if [[ ! -f "$target" ]]; then
    echo "projects: no state file for slug=$slug - call mark_start_state first" >&2
    return 2
  fi
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local json
  json="$(jq \
    --arg ended_at "$now" \
    --arg status "$status" \
    --arg note "$note" \
    '.ended_at = $ended_at | .status = $status | (if ($note | length) > 0 then .notes += [$note] else . end)' \
    "$target")" || { echo "projects: jq failed reading state for slug=$slug" >&2; return 2; }
  projects::_atomic_write_json "$json" "$target"
}

projects::list() {
  local mode="${1:-active}"
  case "$mode" in active|all) ;; *) echo "projects: list mode must be active|all" >&2; return 1 ;; esac
  local dir; dir="$(projects::state_dir)"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if [[ "$mode" == "active" ]]; then
      jq -e 'has("ended_at") | not' "$f" >/dev/null 2>&1 || continue
    fi
    jq -r .slug "$f"
  done
}

projects::show() {
  local slug="$1"
  local target; target="$(projects::state_dir)/${slug}.json"
  if [[ ! -f "$target" ]]; then
    echo "projects: no state file for slug=$slug" >&2
    return 2
  fi
  cat "$target"
}

projects::emit_event() {
  local kind="$1" slug="$2" workstream="$3" terminal_id="$4" status="${5:-}" note_or_description="${6:-}" session_id_arg="${7:-}"
  case "$kind" in start|end) ;; *) echo "projects: emit_event kind must be start|end (got: $kind)" >&2; return 1 ;; esac
  local session_id="${session_id_arg:-${BATON_SESSION_ID:-}}"
  local payload
  if [[ "$kind" == "start" ]]; then
    if [[ -n "$session_id" ]]; then
      payload="$(jq -n \
        --arg slug "$slug" --arg workstream "$workstream" --arg terminal_id "$terminal_id" \
        --arg description "$note_or_description" --arg session_id "$session_id" \
        '{slug: $slug, kind: "start", workstream: $workstream, terminal_id: $terminal_id, description: $description, session_id: $session_id}')"
    else
      payload="$(jq -n \
        --arg slug "$slug" --arg workstream "$workstream" --arg terminal_id "$terminal_id" \
        --arg description "$note_or_description" \
        '{slug: $slug, kind: "start", workstream: $workstream, terminal_id: $terminal_id, description: $description}')"
    fi
  else
    if [[ -n "$session_id" ]]; then
      payload="$(jq -n \
        --arg slug "$slug" --arg workstream "$workstream" --arg terminal_id "$terminal_id" \
        --arg status "$status" --arg note "$note_or_description" --arg session_id "$session_id" \
        '{slug: $slug, kind: "end", workstream: $workstream, terminal_id: $terminal_id, status: $status, note: $note, session_id: $session_id}')"
    else
      payload="$(jq -n \
        --arg slug "$slug" --arg workstream "$workstream" --arg terminal_id "$terminal_id" \
        --arg status "$status" --arg note "$note_or_description" \
        '{slug: $slug, kind: "end", workstream: $workstream, terminal_id: $terminal_id, status: $status, note: $note}')"
    fi
  fi
  envelope::emit project_boundary "$payload"
}

projects::active_for_workstream() {
  local ws="$1"
  local dir; dir="$(projects::state_dir)"
  [[ -d "$dir" ]] || return 0
  local newest='' newest_ts='' f ts slug
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    jq -e --arg ws "$ws" '.workstream == $ws and (has("ended_at") | not)' "$f" >/dev/null 2>&1 || continue
    ts="$(jq -r .started_at "$f")"
    slug="$(jq -r .slug "$f")"
    # ISO-8601 sorts correctly as strings.
    if [[ "$ts" > "$newest_ts" ]]; then
      newest_ts="$ts"
      newest="$slug"
    fi
  done
  printf '%s' "$newest"
}

projects::idle_days() {
  local ws="$1"
  local dir; dir="$(projects::state_dir)"
  [[ -d "$dir" ]] || { echo 999999; return 0; }
  local newest_ts='' f ts
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    jq -e --arg ws "$ws" '.workstream == $ws' "$f" >/dev/null 2>&1 || continue
    ts="$(jq -r .started_at "$f")"
    if [[ "$ts" > "$newest_ts" ]]; then newest_ts="$ts"; fi
  done
  if [[ -z "$newest_ts" ]]; then echo 999999; return 0; fi
  local newest_epoch
  newest_epoch="$(date -u -d "$newest_ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$newest_ts" +%s)"
  local now; now="$(date +%s)"
  echo $(( (now - newest_epoch) / 86400 ))
}
