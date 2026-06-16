#!/usr/bin/env bash
# lib/summary-tokens-mean.sh - running-mean of post-/clear summary-turn output tokens.
# Persisted at $XDG_STATE_HOME/baton/summary-tokens-mean.json.
# Shape: {"n": <int>, "mean": <float>, "skill_hash": "<string>"}.
# Resets to n=1 when skill_hash changes. skill_hash tracks the summary template
# *selection* (its name/id), not its content - editing a template in place keeps
# the same hash and does not reset the mean (sample-pollution risk noted as a
# follow-up; switching templates by name is the common invalidation path).
# Corrupt state (invalid JSON or missing fields) is treated as 'no prior state' and reinitialized.

_stm::path() {
  local base="${XDG_STATE_HOME:-$HOME/.local/state}/baton"
  printf '%s/summary-tokens-mean.json' "$base"
}

_stm::read() {
  local f; f="$(_stm::path)"
  [ -f "$f" ] || return 0
  jq -r '.mean // empty' "$f" 2>/dev/null || true
}

_stm::update() {
  # Usage: _stm::update <tokens> <skill_hash>
  local tokens="$1" hash="$2"
  local f; f="$(_stm::path)"
  local dir; dir="$(dirname "$f")"
  mkdir -p "$dir"
  local lockf="${f}.lock"
  (
    flock 9
    local prev_n prev_mean prev_hash valid=1
    if ! jq -e . "$f" >/dev/null 2>&1; then valid=0; fi
    if [ "$valid" = 1 ]; then
      prev_n=$(jq -r '.n // 0' "$f" 2>/dev/null || echo 0)
      prev_mean=$(jq -r '.mean // 0' "$f" 2>/dev/null || echo 0)
      prev_hash=$(jq -r '.skill_hash // ""' "$f" 2>/dev/null || true)
    else
      prev_n=0; prev_mean=0; prev_hash=""
    fi
    local new_n new_mean
    if [ "$prev_hash" != "$hash" ] || [ "$prev_n" -eq 0 ]; then
      new_n=1
      new_mean="$tokens"
    else
      new_n=$((prev_n + 1))
      new_mean=$(LC_ALL=C awk -v pm="$prev_mean" -v pn="$prev_n" -v t="$tokens" \
        'BEGIN{ printf "%g", (pm*pn + t) / (pn + 1) }')
    fi
    local tmp; tmp=$(mktemp -p "$dir")
    jq -cn --argjson n "$new_n" --argjson m "$new_mean" --arg h "$hash" \
      '{n:$n, mean:$m, skill_hash:$h}' > "$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f"
  ) 9>"$lockf"
}
