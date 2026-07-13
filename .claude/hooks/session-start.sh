#!/bin/bash
# SessionStart hook. Resolves the terminal's workstream binding via
# terminals/<term_hash>.json (creates a fresh workstream if none),
# injects the bound workstream's progress file as a mandatory directive,
# and lists other active workstreams as a switch hint.
# Subagents (AGENT_SESSION_ID set) take a read-only fast path.
set -u

input=$(cat)
SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.cwd')
MATCHER=$(echo "$input" | jq -r '.source // "unknown"')
[ -z "$SESSION_ID" ] && exit 0
[ -z "$CWD" ] && exit 0
[[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

# Source envelope lib (workstream-lib is sourced later - duplicate-safe).
_SS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$_SS_SCRIPT_DIR/lib/envelope.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$_SS_SCRIPT_DIR/lib/session-start-helpers.sh" 2>/dev/null || true

# CC6: source the shared _cfg::get resolver (env > config.json > default).
# Self-contained: guard-source lib/config.sh; if unreachable, define a
# FAITHFUL inline fallback so a dashboard config.json write is still honored
# under plugin distribution. Precedent: .claude/hooks/lib/envelope.sh:26-48.
if ! declare -F _cfg::get >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/config.sh" 2>/dev/null || true
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

: "${_MISSED_SWEEP_MULT:=2}"          # warn after this many missed sweeps
: "${_PREWARM_MIN_SYS_BYTES:=4096}"   # min system-prompt file size to prewarm cache

# Emit SessionStart envelope exactly once on EXIT (CC2). Failures go to stderr,
# never alter the hook exit code.
_SS_WS=""
_SS_TH=""
_SS_BINDING="false"
_SS_EMITTED=0
_emit_ss() {
  [ "$_SS_EMITTED" = "1" ] && return 0
  _SS_EMITTED=1
  local _data
  _data=$(jq -cn \
    --arg m "$MATCHER" \
    --arg ws "$_SS_WS" \
    --arg th "$_SS_TH" \
    --argjson bf "$_SS_BINDING" \
    '{matcher:$m, workstream:$ws, terminal_hash:$th, binding_found:$bf}' 2>/dev/null) || _data='{}'
  envelope::emit "SessionStart" "$_data" 2>/dev/null || true
}
trap _emit_ss EXIT

# AGENT_SESSION_ID Case A - pre-created tracking takes precedence
if [ -n "${AGENT_SESSION_ID:-}" ]; then
  EXISTING_POINTER="/tmp/claude-session-tracking-${SESSION_ID}"
  if [ -f "$EXISTING_POINTER" ]; then
    EXISTING_T_FILE=$(cat "$EXISTING_POINTER")
    if [ -f "$EXISTING_T_FILE" ]; then
      if jq -e '.workstream' "$EXISTING_T_FILE" >/dev/null 2>&1; then
        # Verify the referenced workstream record exists before trusting.
        # Source the lib here (idempotent with later source at line 32) so we
        # can call checkpoint_dir() without an inner subshell.
        _AGENT_WS=$(jq -r '.workstream' "$EXISTING_T_FILE")
        _AGENT_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
        _AGENT_LIB="$(cd "$(dirname "$0")" && pwd)/lib/workstream-lib.sh"
        if [ -f "$_AGENT_LIB" ]; then
          source "$_AGENT_LIB"
          _AGENT_WS_FILE="$(checkpoint_dir "$_AGENT_PROJECT_DIR")/workstreams/${_AGENT_WS}.json"
          if [ -f "$_AGENT_WS_FILE" ]; then
            _SS_WS="$_AGENT_WS"
            _SS_TH=$(term_hash 2>/dev/null || echo "")
            _SS_BINDING="true"
            exit 0  # Case A trusted: workstream record verified
          fi
        fi
        # else: fall through to Case B below
      fi
    fi
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/workstream-lib.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
TRACKING="$(checkpoint_dir "$PROJECT_DIR")"
# WC2: cron-not-running probe - warn if .cron-last-run absent or stale (stale beyond two sweep intervals)
if [ -z "${AGENT_SESSION_ID:-}" ]; then
  _CRON_MARKER="$TRACKING/.cron-last-run"
  _CRON_AGE=-1
  if [ -f "$_CRON_MARKER" ]; then
    _CRON_MTIME=$(stat -c %Y "$_CRON_MARKER" 2>/dev/null || echo 0)
    _CRON_AGE=$(( ($(date -u +%s) - _CRON_MTIME) / 3600 ))
  fi
  _SWEEP_INT_H=$(sweep_interval_hours)
  _CRON_STALE_H=$(( _SWEEP_INT_H * _MISSED_SWEEP_MULT ))   # warn after _MISSED_SWEEP_MULT missed sweeps
  if [ "$_CRON_AGE" -lt 0 ] || [ "$_CRON_AGE" -gt "$_CRON_STALE_H" ]; then
    if [ "$_CRON_AGE" -lt 0 ]; then
      echo "NOTICE: checkpoint state not swept yet; an automatic sweep has just been launched and should clear it shortly (or run \`tools/cleanup-cron.sh\` to force one)."
    else
      echo "NOTICE: checkpoint state last swept ${_CRON_AGE}h ago; an automatic sweep has just been launched and should refresh it shortly (or run \`tools/cleanup-cron.sh\` to force one)."
    fi
    echo ""
  fi
fi
mkdir -p "$TRACKING/workstreams" "$TRACKING/terminals"

# AGENT_SESSION_ID Case B - read-only terminal state. Reached when no
# pre-created tracking, OR pre-created tracking is malformed.
if [ -n "${AGENT_SESSION_ID:-}" ]; then
  TH=$(term_hash)
  TERM_FILE="$TRACKING/terminals/${TH}.json"
  if [ ! -f "$TERM_FILE" ]; then
    echo "ERROR: AGENT_SESSION_ID set but terminals/${TH}.json missing - parent state required for Case B subagent" >&2
    exit 1
  fi
  PARENT_WS=$(jq -r '.workstream // empty' "$TERM_FILE" 2>/dev/null)
  if [ -z "$PARENT_WS" ] || [ ! -f "$TRACKING/workstreams/${PARENT_WS}.json" ]; then
    echo "ERROR: AGENT_SESSION_ID Case B - parent terminal references missing workstream '$PARENT_WS'" >&2
    _SS_TH="$TH"
    exit 1
  fi
  _SS_WS="$PARENT_WS"
  _SS_TH="$TH"
  _SS_BINDING="true"
  # Create per-session tracking only; no terminal_state writes, no injection.
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
  BRANCH_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
  LABEL="${BRANCH_SLUG}-$(date +%Y%m%d-%H%M%S)"
  TRACKING_FILE="$TRACKING/${LABEL}.json"
  jq -n --arg sid "$SESSION_ID" --arg label "$LABEL" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" --arg cwd "$CWD" --arg ws "$PARENT_WS" \
    '{session_id:$sid, label:$label, started_at:$started, branch:$branch, cwd:$cwd, is_worktree:false, workstream:$ws, scope:{paths:[],mode:"exclusive"}, files:[], progress_file:null}' \
    > "$TRACKING_FILE"
  echo "$TRACKING_FILE" > "/tmp/claude-session-tracking-${SESSION_ID}"
  exit 0
fi

TH=$(term_hash)
TS=$(term_hash_source)
TERM_FILE="$TRACKING/terminals/${TH}.json"
_SS_TH="$TH"

# Prefix: WORKSTREAM env var override
if [ -n "${WORKSTREAM:-}" ]; then
  if ! [[ "$WORKSTREAM" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: WORKSTREAM='$WORKSTREAM' rejected - must match [a-zA-Z0-9_-]+" >&2
    exit 1
  fi
  WS_PATH="$TRACKING/workstreams/${WORKSTREAM}.json"
  if [ -f "$WS_PATH" ]; then
    # Corrupt-JSON guard (spec line 324, F10)
    if ! _WS_ERR=$(jq -e . "$WS_PATH" 2>&1 >/dev/null); then
      printf 'WORKSTREAM=%s but workstreams/%s.json is corrupt: %s\n' "$WORKSTREAM" "$WORKSTREAM" "$_WS_ERR" >&2
      exit 1
    fi
  else
    if [ -z "${AGENT_SESSION_ID:-}" ]; then
      echo "NOTE: WORKSTREAM=$WORKSTREAM not found - creating it"
      echo ""
    fi
    DISPLAY=$(derive_display_name "$CWD" "$PROJECT_DIR" "$WORKSTREAM")
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n --arg ws "$WORKSTREAM" --arg dn "$DISPLAY" --arg ts "$NOW" --arg pd "$CWD" \
      '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:$ts, project_dir:$pd}' \
      | atomic_write "$WS_PATH"
  fi
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg tid "$TS" --arg ws "$WORKSTREAM" --arg ts "$NOW" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    | atomic_write "$TERM_FILE"
fi

# Register parent session_id for subagent checkpoint lookup
echo "$SESSION_ID" > "/tmp/claude-parent-sid-${TH}"

# --- Routing rule body (Wave 4 fills in remaining branches) ---
WS_NAME=""
if [ -f "$TERM_FILE" ]; then
  WS_NAME=$(jq -r '.workstream // empty' "$TERM_FILE" 2>/dev/null)
fi
# E1 hardening: a terminal HIT can be STALE. When CLAUDE_TERMINAL_ID is unset,
# term_hash falls back to md5(user:tty); after a reboot a reused tty collides with
# a prior workstream's terminals/<hash>.json, binding a resumed session to the
# wrong (stale) workstream. If the LIVE session_id is authoritatively stamped on a
# DIFFERENT workstream, the resumed session belongs there - divert + correct the
# stale binding. Gated off source=clear: on /clear the terminal binding is
# legitimate and MUST win even when a decoy record carries the id (E1-A). When no
# other workstream claims this id (the normal case) the terminal binding stands.
if [ -n "$WS_NAME" ] && [ "$MATCHER" != "clear" ]; then
  _REACQ_WS=$(find_workstream_by_session_id "$TRACKING" "$SESSION_ID")
  if [ -n "$_REACQ_WS" ] && [ "$_REACQ_WS" != "$WS_NAME" ]; then
    log_event "$PROJECT_DIR" session-start rebind-stale-terminal "from=$WS_NAME" "to=$_REACQ_WS" "session_id=$SESSION_ID" 2>/dev/null
    WS_NAME="$_REACQ_WS"
    rebind_terminal "$TRACKING" "$WS_NAME"
  fi
fi
if [ -z "$WS_NAME" ]; then
  # E1 crash recovery: terminal binding missing (new terminal after a crash/
  # reboot). Before minting fresh, reverse-lookup a workstream whose session_id
  # == this (resumed) session's id and rebind THIS terminal onto it. Reached
  # ONLY on a terminal-miss, so /clear (terminal hit above) never consults
  # session_id - non-interference is structural, not a source:resume gate.
  _REACQ_WS=$(find_workstream_by_session_id "$TRACKING" "$SESSION_ID")
  if [ -n "$_REACQ_WS" ]; then
    WS_NAME="$_REACQ_WS"
    rebind_terminal "$TRACKING" "$WS_NAME"
    log_event "$PROJECT_DIR" session-start reacquire-by-session-id "workstream=$WS_NAME" "session_id=$SESSION_ID" 2>/dev/null
    if [ -z "${AGENT_SESSION_ID:-}" ]; then
      echo "NOTE: terminal binding missing; reacquired workstream '$WS_NAME' via session_id."
      echo ""
    fi
  fi
fi
if [ -z "$WS_NAME" ]; then
  # State missing or unparseable → create fresh workstream + bind
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  BRANCH_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
  WS_NAME="${BRANCH_SLUG}-$(date +%Y%m%d-%H%M%S)-${TH:0:6}"
  DISPLAY=$(derive_display_name "$CWD" "$PROJECT_DIR" "$WS_NAME")
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "$WS_NAME" --arg dn "$DISPLAY" --arg ts "$NOW" --arg pd "$CWD" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:$ts, project_dir:$pd}' \
    | atomic_write "$TRACKING/workstreams/${WS_NAME}.json"
  jq -n --arg tid "$TS" --arg ws "$WS_NAME" --arg ts "$NOW" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    | atomic_write "$TERM_FILE"
fi

WS_FILE="$TRACKING/workstreams/${WS_NAME}.json"

# Probe workstream file: missing OR unparseable → fall through with note
WS_VALID=true
if [ ! -f "$WS_FILE" ]; then
  WS_VALID=false
elif ! jq -e . "$WS_FILE" >/dev/null 2>&1; then
  WS_VALID=false
fi

if [ "$WS_VALID" = false ]; then
  if [ -z "${AGENT_SESSION_ID:-}" ]; then
    echo "NOTE: previous workstream unavailable ('$WS_NAME'), starting fresh."
    echo ""
  fi
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  BRANCH_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
  WS_NAME="${BRANCH_SLUG}-$(date +%Y%m%d-%H%M%S)-${TH:0:6}"
  DISPLAY=$(derive_display_name "$CWD" "$PROJECT_DIR" "$WS_NAME")
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "$WS_NAME" --arg dn "$DISPLAY" --arg ts "$NOW" --arg pd "$CWD" \
    '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:$ts, project_dir:$pd}' \
    | atomic_write "$TRACKING/workstreams/${WS_NAME}.json"
  jq -n --arg tid "$TS" --arg ws "$WS_NAME" --arg ts "$NOW" \
    '{terminal_id:$tid, workstream:$ws, updated_at:$ts}' \
    | atomic_write "$TERM_FILE"
  WS_FILE="$TRACKING/workstreams/${WS_NAME}.json"
fi

# E1 crash-recovery anchor: stamp session_id on the resolved workstream record.
# Additive field, off the routing path (only READ on a later terminal-miss), so
# it cannot disturb /clear. Refreshed every main-session SessionStart; subagent
# Cases A/B exited far above and never reach here. WS_FILE is parseable (WS_VALID).
jq --arg sid "$SESSION_ID" '.session_id = $sid' "$WS_FILE" | atomic_write "$WS_FILE"

WS_PROGRESS=$(jq -r '.progress_file // empty' "$WS_FILE" 2>/dev/null)
WS_PHASE=$(jq -r '.phase // "unknown"' "$WS_FILE" 2>/dev/null)
WS_DISPLAY=$(jq -r '.display_name // empty' "$WS_FILE" 2>/dev/null)

# Three-state progress handling (Task 15 expands)
if [ -z "$WS_PROGRESS" ]; then
  : # silent - fresh workstream, no checkpoint yet
elif [ -f "$PROJECT_DIR/$WS_PROGRESS" ] || [ -f "$WS_PROGRESS" ]; then
  RESOLVED="$WS_PROGRESS"
  [ -f "$PROJECT_DIR/$WS_PROGRESS" ] && RESOLVED="$PROJECT_DIR/$WS_PROGRESS"
  if [ -z "${AGENT_SESSION_ID:-}" ]; then
    echo "--- Workstream Progress (auto-injected) ---"
    echo "IMPORTANT: This progress file IS your assignment. Resume exactly where the previous session stopped."
    echo "Follow the What's Next section literally. Do NOT reinterpret, re-scope, or start fresh."
    echo ""
    cat "$RESOLVED"
    echo ""
    echo "--- End Progress ---"
    echo ""
  fi
else
  if [ -z "${AGENT_SESSION_ID:-}" ]; then
    echo "WARNING: Workstream '${WS_DISPLAY:-$WS_NAME}' progress file is set but missing - previous session may have crashed mid-checkpoint. Check git log for recent work."
    echo ""
  fi
fi

# Bump terminals/<hash>.json updated_at; stamp the tmux pane id when inside
# tmux so E6 same-terminal automation can target this exact pane (absent
# outside tmux -> injector degrades to a clean no-op).
_tmux_pane=""
[ -n "${TMUX:-}" ] && _tmux_pane="${TMUX_PANE:-}"
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pane "$_tmux_pane" \
  '.updated_at = $ts | (if $pane == "" then del(.tmux_pane) else .tmux_pane = $pane end)' "$TERM_FILE" \
  | atomic_write "$TERM_FILE"

# List other active workstreams so user can see/switch
if [ -z "${AGENT_SESSION_ID:-}" ]; then
  OTHERS=""
  for f in "$TRACKING"/workstreams/*.json; do
    [ -f "$f" ] || continue
    OWS=$(jq -r '.workstream // empty' "$f")
    if [ -z "$OWS" ] || [ "$OWS" = "$WS_NAME" ]; then continue; fi
    ODN=$(jq -r '.display_name // empty' "$f")
    if [ -n "$ODN" ]; then
      OTHERS="${OTHERS}  - ${ODN} (${OWS})\n"
    else
      OTHERS="${OTHERS}  - ${OWS}\n"
    fi
  done
  # Opportunistic project-boundary nudge (E12 / L0 B1).
  # declare-f guard: helper source above uses `|| true`, so the function may be
  # undefined if session-start-helpers.sh is missing on a partial install.
  if declare -f session_start::maybe_project_prompt >/dev/null 2>&1; then
    _ss_project_prompt="$(session_start::maybe_project_prompt "$WS_NAME")"
    if [[ -n "$_ss_project_prompt" ]]; then
      echo ''
      echo '--- Project Tracking ---'
      echo "$_ss_project_prompt"
    fi
  fi
  if [ -n "$OTHERS" ]; then
    printf "\nOther active workstreams (mention by name to switch):\n%b\n" "$OTHERS"
  fi
fi

# Per-session tracking file (kept for tools that read /tmp/claude-session-tracking-${SID})
# AGENT_SESSION_ID Cases A and B are added cleanly at the top of the file in Tasks 19/20.
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
BRANCH_SLUG=$(echo "$BRANCH" | sed 's|/|-|g')
LABEL="${BRANCH_SLUG}-$(date +%Y%m%d-%H%M%S)"
TRACKING_FILE="$TRACKING/${LABEL}.json"
jq -n --arg sid "$SESSION_ID" --arg label "$LABEL" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg branch "$BRANCH" --arg cwd "$CWD" \
  --arg ws "$WS_NAME" \
  '{session_id:$sid, label:$label, started_at:$started, branch:$branch, cwd:$cwd, is_worktree:false, workstream:$ws, scope:{paths:[],mode:"exclusive"}, files:[], progress_file:null}' \
  > "$TRACKING_FILE"
echo "$TRACKING_FILE" > "/tmp/claude-session-tracking-${SESSION_ID}"

_SS_WS="$WS_NAME"
_SS_BINDING="true"

# E8-T8: pre-warm begin
# ---------------------------------------------------------------------------
# Cache pre-warm - fires a max_tokens:0 request to seed the prompt cache.
# Gate: BATON_PREWARM=1, matcher in {clear,resume}, ANTHROPIC_API_KEY set,
#       BATON_PREWARM_SYSTEM_FILE exists + readable + >=_PREWARM_MIN_SYS_BYTES bytes.
# Default: BATON_PREWARM=0 (inert).
#
# Mock seam: override prewarm::_request(body→stdin) → writes HTTP response body
# to stdout; sets _PREWARM_HTTP_STATUS global; exits 0 on 200, nonzero on non-200.
# Tests set PREWARM_MOCK_REQUEST_FILE to capture the request body.
# ---------------------------------------------------------------------------

prewarm::_request() {
  # Takes request body on stdin.
  # Output format (two lines):
  #   Line 1: HTTP status code (e.g. "200", "400")
  #   Line 2: raw JSON response body
  # Returns 0 on HTTP 200, nonzero otherwise.
  #
  # Mock seam: set PREWARM_REQUEST_SHIM to an executable path. That shim is
  # called instead of curl. It reads stdin (request body), writes its output
  # in the same two-line format (status code on line 1, body on line 2), and
  # returns 0 on 200 / nonzero on non-200. Tests also set
  # PREWARM_MOCK_REQUEST_FILE to capture the request body the shim receives.
  local body
  body=$(cat)
  if [ -n "${PREWARM_REQUEST_SHIM:-}" ] && [ -x "${PREWARM_REQUEST_SHIM}" ]; then
    printf '%s' "$body" | "${PREWARM_REQUEST_SHIM}"
    return $?
  fi
  local resp http_code
  resp=$(printf '%s' "$body" | curl -sS -w '\n__HTTP_STATUS__%{http_code}' \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @- 2>/dev/null)
  http_code=$(printf '%s' "$resp" | grep -o '__HTTP_STATUS__[0-9]*' | sed 's/__HTTP_STATUS__//')
  local body_only; body_only=$(printf '%s' "$resp" | grep -v '__HTTP_STATUS__')
  printf '%s\n%s' "${http_code:-0}" "$body_only"
  [ "${http_code:-0}" = "200" ] && return 0 || return 1
}

_prewarm_run() {
  # All gates must pass; any miss = silent return.
  [ "$(_cfg::get BATON_PREWARM 0)" = "1" ] || return 0
  case "$MATCHER" in clear|resume) ;; *) return 0 ;; esac
  [ -n "${ANTHROPIC_API_KEY:-}" ] || return 0
  local sys_file="${BATON_PREWARM_SYSTEM_FILE:-}"
  [ -n "$sys_file" ] && [ -r "$sys_file" ] || return 0
  local fsize; fsize=$(wc -c < "$sys_file" 2>/dev/null || echo 0)
  [ "$fsize" -ge "$_PREWARM_MIN_SYS_BYTES" ] || return 0

  # Source cost model for model resolution and pricing.
  # Hook lives at .claude/hooks/; lib/ is at repo root (two levels up).
  local _lib_dir; _lib_dir="$(cd "${_SS_SCRIPT_DIR}/../.." && pwd)/lib"
  # shellcheck source=../../lib/cost-models.sh
  source "$_lib_dir/cost-models.sh" 2>/dev/null || return 0

  local alias_model; alias_model="$(_cfg::get BATON_COST_MODEL claude-sonnet-4-6)"
  local model_id; model_id=$(cost_models::resolve_id "$alias_model" 2>/dev/null)

  # Build request body via jq.
  local sys_text; sys_text=$(cat "$sys_file")
  local req_body
  req_body=$(jq -cn \
    --arg model "$model_id" \
    --arg text "$sys_text" \
    '{model:$model,
      max_tokens:0,
      system:[{type:"text",text:$text,cache_control:{type:"ephemeral"}}],
      messages:[{role:"user",content:"warmup"}]}')

  # Call the (mockable) request function.
  # Output: first line = HTTP status code, remaining lines = JSON body.
  local raw_resp; raw_resp=$(printf '%s' "$req_body" | prewarm::_request)
  local http_status; http_status=$(printf '%s' "$raw_resp" | head -n1)
  local resp_body; resp_body=$(printf '%s' "$raw_resp" | tail -n +2)

  if [ "$http_status" = "200" ]; then
    local cache_tokens
    cache_tokens=$(printf '%s' "$resp_body" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)
    envelope::emit "prewarm_ok" \
      "$(jq -cn --arg m "$model_id" --argjson ct "$cache_tokens" \
           '{model:$m, cache_creation_input_tokens:$ct}')" 2>/dev/null || true

    # Cost estimate: cache_creation × cache_write_5m / 1_000_000
    local price_per_mtok; price_per_mtok=$(cost_models::price "$alias_model" "cache_write_5m" 2>/dev/null || echo 0)
    local usd
    usd=$(awk -v ct="$cache_tokens" -v p="$price_per_mtok" \
          'BEGIN { printf "%.4f", ct * p / 1000000 }')
    printf 'baton: pre-warm (5m) requested for %s; cache_creation=%s; estimated cost ≈ $%s\n' \
      "$model_id" "$cache_tokens" "$usd" >&2
  else
    local err_msg
    err_msg=$(printf '%s' "$resp_body" | jq -r '.error.message // "unknown"' 2>/dev/null || echo "unknown")
    envelope::emit "prewarm_failed" \
      "$(jq -cn --arg sc "$http_status" --arg e "$err_msg" \
           '{status_code:$sc, error:$e}')" 2>/dev/null || true
  fi
}

_prewarm_run
# E8-T8: pre-warm end

# E-D1: fire the periodic sweep self-throttled (--if-due) and FULLY DETACHED so it
# never delays session readiness. Forwards the resolved PROJECT_DIR so the sweep
# targets the right data tree. Guarded under set -u; missing var/script can't abort.
SWEEP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd -P)/cleanup-cron.sh"
if [ -x "$SWEEP" ]; then
  if command -v setsid >/dev/null 2>&1; then
    BATON_PROJECT_DIR="$PROJECT_DIR" setsid bash "$SWEEP" --if-due >/dev/null 2>&1 </dev/null &
  else
    BATON_PROJECT_DIR="$PROJECT_DIR" nohup bash "$SWEEP" --if-due >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
fi

# E-G: auto-tick the threshold controller ONCE per main session, gated on collection.
# run_once is lightweight and, under the placeholder score_hold, a guaranteed no-op; it only
# runs when collection is on (an open arc or BATON_COLLECT=1), so a normal session pays
# nothing. Applying here lands any new threshold in config.json before this session's first
# PreToolUse checkpoint reads it. The subagent (Case B) path exited above, so subagents never tune.
_TUNE_CTRL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd -P)/threshold-controller.sh"
if [ -r "$_TUNE_CTRL" ]; then
  # shellcheck disable=SC1090
  source "$_TUNE_CTRL" 2>/dev/null || true
  if declare -F threshold_controller::collection_on >/dev/null 2>&1 \
     && threshold_controller::collection_on; then
    threshold_controller::run_once >/dev/null 2>&1 || true
    # E-H: record this session's resolved tuner knob vector (joins to cost_rollup/outcome_proxy
    # by session_id). Read-only; threshold read AFTER run_once so it reflects any apply. Reached
    # only inside this collection gate; envelope::emit self-gates too.
    if declare -F threshold_controller::emit_snapshot >/dev/null 2>&1; then
      threshold_controller::emit_snapshot "$SESSION_ID" >/dev/null 2>&1 || true
    fi
  fi
fi

exit 0
