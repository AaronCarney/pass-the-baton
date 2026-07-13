#!/usr/bin/env bash
# post-tool-batch.sh - E8-T6 cost telemetry hook.
# Fires on PostToolBatch: reads latest usage from transcript, emits cost_rollup.
# Detects cache_creation doubling vs prior turn → emits cache_anomaly warning.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/envelope.sh
source "$HOOKS_DIR/lib/envelope.sh"
# shellcheck source=lib/usage-tokens.sh
source "$HOOKS_DIR/lib/usage-tokens.sh"

: "${_CACHE_ANOMALY_MULT:=2}"   # creation-count spike ratio that flags a cache anomaly

# Path computation matches the existing hook pattern (e.g., .claude/hooks/anomaly-detector.sh).
_hook_dir="${BASH_SOURCE[0]%/*}"
_repo_root="$(cd "$_hook_dir/../.." && pwd -P)"
# shellcheck disable=SC1091
source "$_repo_root/lib/summary-tokens-mean.sh"
# shellcheck disable=SC1091
source "$_repo_root/lib/config.sh"

# E-C: active threshold for self-describing cost data. workstream-lib is functions-only.
if ! declare -F checkpoint_threshold >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$HOOKS_DIR/lib/workstream-lib.sh" 2>/dev/null || true
fi

# --- read stdin payload -------------------------------------------------------
payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""')
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // ""')

# Best-effort: if no transcript, don't block the turn.
[ -z "$transcript_path" ] && exit 0
[ ! -f "$transcript_path" ] && exit 0

# --- extract last assistant usage block --------------------------------------
usage_json=$(tail -n "$_TRANSCRIPT_SCAN_LINES" "$transcript_path" \
  | jq -s '[.[] | select(.message.role=="assistant") | .message.usage] | last' 2>/dev/null)

[ -z "$usage_json" ] || [ "$usage_json" = "null" ] && exit 0

# Extract model from last assistant message.
model=$(tail -n "$_TRANSCRIPT_SCAN_LINES" "$transcript_path" \
  | jq -rs '[.[] | select(.message.role=="assistant") | .message.model] | last // ""' 2>/dev/null)

# --- parse token fields -------------------------------------------------------
# Spec line 367 / Brief 4 §10: the 1h-TTL split is exposed as
# ephemeral_5m_input_tokens + ephemeral_1h_input_tokens, else the flat
# cache_creation_input_tokens. Must match tools/cost.sh's extractor
# verbatim so the two cost readers never disagree on the same transcript.
# Shared with post-subagent-cost.sh via lib/usage-tokens.sh.
IFS=$'\t' read -r cache_read cache_write_5m cache_write_1h fresh_input output \
  <<<"$(usage_tokens::extract "$usage_json")"

# Total write tokens for anomaly detection: detailed split when present,
# else the flat total (same precedence as the per-primitive reads above).
current_creation=$(printf '%s' "$usage_json" | jq -r '
  if (.ephemeral_5m_input_tokens != null or .ephemeral_1h_input_tokens != null) then
    (.ephemeral_5m_input_tokens // 0) + (.ephemeral_1h_input_tokens // 0)
  else
    (.cache_creation_input_tokens // 0)
  end' 2>/dev/null || echo 0)

transcript_basename=$(basename "$transcript_path")

# --- determine turn_index (count of assistant messages seen) -----------------
turn_index=$(tail -n "$_TRANSCRIPT_SCAN_LINES" "$transcript_path" \
  | jq -s '[.[] | select(.message.role=="assistant")] | length' 2>/dev/null || echo 0)

# --- /clear sentinel + summary_turn detection --------------------------------
# turn_index dropping vs the prior value for the same session_id is the cheapest
# /clear signal (auto-summary restarts the assistant-message count). Tag the
# first cost_rollup after a /clear as summary_turn:true and feed its output
# tokens into the running-mean state consumed by cost-compare (T7).
summary_turn_bool=false  # default for no-prior-state, missing-state, corrupt-state branches
sentstate="${XDG_STATE_HOME:-$HOME/.local/state}/baton/clear-sentinel-state.json"
lockf="${sentstate}.lock"
mkdir -p "$(dirname "$sentstate")"
prior_last_turn_index=0
if [ -f "$sentstate" ] && jq -e . "$sentstate" >/dev/null 2>&1; then
  prior_last_turn_index=$(jq -r --arg s "$session_id" '.[$s].last_turn_index // 0' "$sentstate")
fi
if [ "$prior_last_turn_index" -gt 0 ] && [ "$turn_index" -lt "$prior_last_turn_index" ]; then
  summary_turn_bool=true
fi
# Write under flock for cross-session safety.
(
  flock 9
  tmp=$(mktemp -p "$(dirname "$sentstate")")
  if [ -f "$sentstate" ] && jq -e . "$sentstate" >/dev/null 2>&1; then
    jq --arg s "$session_id" --argjson ti "$turn_index" '.[$s] = {last_turn_index:$ti}' "$sentstate" > "$tmp"
  else
    jq -cn --arg s "$session_id" --argjson ti "$turn_index" '{($s):{last_turn_index:$ti}}' > "$tmp"
  fi
  mv "$tmp" "$sentstate"
) 9>"$lockf"

# On detection: record summary-turn output tokens into the running mean.
# Zero-output summary turns still get tagged but contribute no sample.
if [ "$summary_turn_bool" = true ] && [ "$output" -gt 0 ]; then
  skill_hash="$(_cfg::get template free)"
  _stm::update "$output" "$skill_hash"
fi

# --- emit cost_rollup event ---------------------------------------------------
data_json=$(jq -cn \
  --arg session_id "$session_id" \
  --arg model "$model" \
  --argjson cache_read "$cache_read" \
  --argjson cache_write_5m "$cache_write_5m" \
  --argjson cache_write_1h "$cache_write_1h" \
  --argjson fresh_input "$fresh_input" \
  --argjson output "$output" \
  --argjson turn_index "$turn_index" \
  --argjson summary_turn "$summary_turn_bool" \
  --argjson threshold "$(checkpoint_threshold)" \
  --arg transcript_basename "$transcript_basename" \
  '{session_id:$session_id, model:$model, threshold:$threshold, cache_read:$cache_read,
    cache_write_5m:$cache_write_5m, cache_write_1h:$cache_write_1h,
    fresh_input:$fresh_input, output:$output,
    turn_index:$turn_index, summary_turn:$summary_turn,
    transcript_basename:$transcript_basename}')

envelope::emit cost_rollup "$data_json"

# --- anomaly detection --------------------------------------------------------
# State file: keyed by session_id, stores last cache_creation value.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
state_file="$state_dir/cost-anomaly-state.json"
lock_file="$state_file.lock"

mkdir -p "$state_dir"
if [ ! -e "$state_file" ]; then
  printf '{}' > "$state_file"
  chmod 0600 "$state_file"
fi
chmod 0600 "$state_file" 2>/dev/null || true

# Read-modify-write the per-session anomaly state under one lock. The prior
# value read, the doubling decision, and the write must be atomic: two
# concurrent post-tool invocations reading the same prior_creation would
# either double-fire the anomaly or clobber each other's update.
(
  flock 9
  prior_creation=$(jq -r --arg sid "$session_id" '.[$sid] // 0' "$state_file" 2>/dev/null || echo 0)
  prior_creation=${prior_creation:-0}

  if [ "$prior_creation" -gt 0 ] && [ "$current_creation" -ge $((prior_creation * _CACHE_ANOMALY_MULT)) ]; then
    ratio=$(jq -cn --argjson c "$current_creation" --argjson p "$prior_creation" '$c / $p')
    anomaly_json=$(jq -cn \
      --arg session_id "$session_id" \
      --argjson prior_creation "$prior_creation" \
      --argjson current_creation "$current_creation" \
      --argjson ratio "$ratio" \
      '{session_id:$session_id, prior_creation:$prior_creation,
        current_creation:$current_creation, ratio:$ratio}')
    envelope::emit cache_anomaly "$anomaly_json"
  fi

  new_state=$(jq --arg sid "$session_id" --argjson val "$current_creation" \
    '.[$sid] = $val' "$state_file" 2>/dev/null)
  if [ -n "$new_state" ]; then
    printf '%s' "$new_state" > "$state_file"
    chmod 0600 "$state_file" 2>/dev/null || true
  fi
) 9>"$lock_file"

exit 0
