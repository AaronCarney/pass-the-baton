#!/usr/bin/env bash
# post-subagent-cost.sh - E20-T2 sub-agent cost telemetry hook (CC16).
# Fires on SubagentStop: the payload provides the sub-agent's OWN transcript at
# agent_transcript_path (plus agent_id / agent_type); transcript_path is the
# PARENT session transcript and is NOT read (reading it leaked the parent's
# usage under source:subagent - corrected per the 2026-06-10 live payload
# capture, CC16). Reads agent_transcript_path, extracts the last assistant
# usage, and emits a cost_rollup. envelope::emit stamps project_slug+method for
# the inherited CLAUDE_TERMINAL_ID's open arc - the ONLY way sub-agent spend
# enters per-arc totals, since the parent's PostToolBatch never sees it.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/envelope.sh
source "$HOOKS_DIR/lib/envelope.sh"
# shellcheck source=lib/usage-tokens.sh
source "$HOOKS_DIR/lib/usage-tokens.sh"

# --- read stdin payload ------------------------------------------------------
payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""')
agent_transcript_path=$(printf '%s' "$payload" | jq -r '.agent_transcript_path // ""')
agent_id=$(printf '%s' "$payload" | jq -r '.agent_id // ""')
agent_type=$(printf '%s' "$payload" | jq -r '.agent_type // ""')

# Best-effort: if no sub-agent transcript, don't block the turn. NO fallback to
# transcript_path - that is the parent session and would re-leak parent usage.
[ -z "$agent_transcript_path" ] && exit 0

# --- extract last assistant usage block -------------------------------------
# SubagentStop can fire before the sub-agent's final (usage-bearing) assistant
# message is flushed to its transcript - observed live dropping ~2/3 of
# dispatches, which read a partial transcript and saw null usage (CC16). Poll
# until the usage line appears, bounded well inside the hook's 5s timeout, so
# per-arc sub-agent spend is not silently lost.
usage_json=""
for _ in $(seq 1 ${CC16_USAGE_POLL_TRIES:-20}); do
  [ -f "$agent_transcript_path" ] && usage_json=$(tail -n 50 "$agent_transcript_path" \
    | jq -s '[.[] | select(.message.role=="assistant") | .message.usage] | last' 2>/dev/null)
  [ -n "$usage_json" ] && [ "$usage_json" != "null" ] && break
  usage_json=""
  sleep "${CC16_USAGE_POLL_SLEEP:-0.15}"
done

[ -z "$usage_json" ] && exit 0

# Extract model from last assistant message.
model=$(tail -n 50 "$agent_transcript_path" \
  | jq -rs '[.[] | select(.message.role=="assistant") | .message.model] | last // ""' 2>/dev/null)

# --- parse token fields ------------------------------------------------------
IFS=$'\t' read -r cache_read cache_write_5m cache_write_1h fresh_input output \
  < <(usage_tokens::extract "$usage_json")

# --- build + emit cost_rollup ------------------------------------------------
data_json=$(jq -cn \
  --arg sid "$session_id" \
  --arg model "$model" \
  --arg aid "$agent_id" \
  --arg atype "$agent_type" \
  --argjson cr "$cache_read" \
  --argjson cw5 "$cache_write_5m" \
  --argjson cw1 "$cache_write_1h" \
  --argjson fi "$fresh_input" \
  --argjson out "$output" \
  --arg tb "$(basename "$agent_transcript_path")" \
  '{session_id:$sid, model:$model, agent_id:$aid, agent_type:$atype,
    cache_read:$cr, cache_write_5m:$cw5,
    cache_write_1h:$cw1, fresh_input:$fi, output:$out,
    transcript_basename:$tb, source:"subagent"}')

envelope::emit cost_rollup "$data_json"

exit 0
