#!/bin/bash
# PostToolUse hook (matcher: "" - all tools). Optional per-tool latency
# telemetry. When BATON_TIMING=1, emits a tool_call event with the
# SDK-provided duration_ms plus the hook's own emission overhead. Off by
# default - gate is checked before reading stdin in any meaningful way.
#
# Coexists with checkpoint-write-trigger.sh, which matches only
# Write|Edit|MultiEdit on progress-*.md files. The two hooks emit
# different event names (PostToolUse vs tool_call) so analysis tools
# do not conflate them.
#
# Self-measurement: hook_overhead_ms records the wall-clock spent in
# this script (excluding the final envelope::emit append). Lets tools/
# latency.sh report the instrumentation tax the user is paying.
set -u

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

# Fast off-path: drain stdin to avoid SIGPIPE on the SDK side, then exit.
# Sub-ms cost vs the ~15-30ms on-path so the off-default is genuinely cheap.
if [ "$(_cfg::get BATON_TIMING 0)" != "1" ]; then
  cat > /dev/null
  exit 0
fi

_TT_START_NS=$(date +%s%N 2>/dev/null || echo 0)
# BSD date (macOS without coreutils) leaves +%N literal - guard so arithmetic
# below never trips set -u with a non-numeric value.
[[ "$_TT_START_NS" =~ ^[0-9]+$ ]] || _TT_START_NS=0

input=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/envelope.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/workstream-lib.sh" 2>/dev/null || true

TOOL_NAME=$(echo "$input" | jq -r '.tool_name // "unknown"')
DURATION_MS=$(echo "$input" | jq -r '.duration_ms // 0')
TOOL_USE_ID=$(echo "$input" | jq -r '.tool_use_id // ""')
CWD=$(echo "$input" | jq -r '.cwd // ""')

# SDK delivers integer duration_ms; guard against malformed / missing payloads.
[[ "$DURATION_MS" =~ ^[0-9]+$ ]] || DURATION_MS=0

# Workstream resolution - same pattern as checkpoint-write-trigger.sh.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"
WORKSTREAM=""
TH=""
if command -v checkpoint_dir >/dev/null 2>&1; then
  TRACKING_DIR=$(checkpoint_dir "$PROJECT_DIR" 2>/dev/null || echo "")
  TH=$(term_hash 2>/dev/null || echo "")
  if [ -n "$TRACKING_DIR" ] && [ -n "$TH" ]; then
    TERM_FILE="$TRACKING_DIR/terminals/${TH}.json"
    [ -f "$TERM_FILE" ] && WORKSTREAM=$(jq -r '.workstream // empty' "$TERM_FILE" 2>/dev/null)
  fi
fi

_TT_END_NS=$(date +%s%N 2>/dev/null || echo 0)
[[ "$_TT_END_NS" =~ ^[0-9]+$ ]] || _TT_END_NS=0
HOOK_OVERHEAD_MS=$(( (_TT_END_NS - _TT_START_NS) / 1000000 ))
[ "$HOOK_OVERHEAD_MS" -lt 0 ] && HOOK_OVERHEAD_MS=0

DATA=$(jq -cn \
  --arg tn "$TOOL_NAME" \
  --arg ws "${WORKSTREAM:-}" \
  --arg th "$TH" \
  --arg tui "$TOOL_USE_ID" \
  --argjson dur "$DURATION_MS" \
  --argjson oh "$HOOK_OVERHEAD_MS" \
  '{tool_name:$tn, duration_ms:$dur, hook_overhead_ms:$oh,
    workstream:$ws, terminal_hash:$th, tool_use_id:$tui}' 2>/dev/null) || DATA='{}'

envelope::emit "tool_call" "$DATA" 2>/dev/null || true

exit 0
