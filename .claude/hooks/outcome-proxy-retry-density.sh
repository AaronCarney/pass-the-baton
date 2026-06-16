#!/usr/bin/env bash
# .claude/hooks/outcome-proxy-retry-density.sh - UserPromptSubmit hook for the triage retry-density proxy.
# Privacy (L0 D1 / L1 §E16 line 208): prompt TEXT never appears in event payload.
# Only the scalar Jaccard similarity + n_prior_prompts integer leave the hook.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/outcome-proxies.sh"

outcome_proxies::consent_on || exit 0

N_RING=5
stdin_json=$(cat)
[ -z "$stdin_json" ] && exit 0

prompt=$(printf '%s' "$stdin_json" | jq -r '.prompt // empty')
session_id=$(printf '%s' "$stdin_json" | jq -r '.session_id // empty')
[ -z "$prompt" ] && exit 0
# Ring file is keyed by session_id; use a stable sentinel for absent sessions
# so the ring still works, but DO NOT propagate the sentinel into the emitted
# event payload (consumers see session_id omitted, matching T2 code-execution).
ring_session_key="${session_id:-no-session}"

# Tokenize: lowercase, whitespace-split, dedupe → JSON array.
tokens_json=$(printf '%s' "$prompt" \
  | tr 'A-Z' 'a-z' \
  | tr -cs 'a-z0-9' ' ' \
  | tr ' ' '\n' \
  | awk 'length($0)>0' \
  | sort -u \
  | jq -R . | jq -cs .)

ring_dir="${XDG_STATE_HOME:-$HOME/.local/state}/baton/outcome-proxies"
mkdir -p "$ring_dir"
chmod 0700 "$ring_dir" 2>/dev/null || true
ring_file="$ring_dir/retry-ring-${ring_session_key}.jsonl"
[ -f "$ring_file" ] || ( umask 0177; : >> "$ring_file" )
chmod 0600 "$ring_file" 2>/dev/null || true

# Compute max Jaccard vs existing ring entries.
max_sim="0"
n_prior=0
if [ -s "$ring_file" ]; then
  while IFS= read -r prior; do
    [ -z "$prior" ] && continue
    n_prior=$((n_prior+1))
    sim=$(jq -cn --argjson a "$tokens_json" --argjson b "$prior" '
      ($a | length) as $la
      | ($b | length) as $lb
      | (($a + $b) | unique | length) as $u
      | (($a - ($a - $b)) | length) as $i
      | if $u == 0 then 0 else ($i / $u) end
    ')
    awk -v m="$max_sim" -v s="$sim" 'BEGIN{exit !(s>m)}' && max_sim="$sim"
  done < "$ring_file"
fi

# Append current tokens; truncate ring to last N.
printf '%s\n' "$tokens_json" >> "$ring_file"
tmp=$(mktemp "${ring_file}.XXXXXX")
tail -n "$N_RING" "$ring_file" > "$tmp" && mv "$tmp" "$ring_file"
chmod 0600 "$ring_file" 2>/dev/null || true

if [ -n "$session_id" ]; then
  proxy_payload=$(jq -cn \
    --argjson similarity "$max_sim" \
    --argjson n_prior_prompts "$n_prior" \
    --arg session_id "$session_id" \
    '{similarity: $similarity, n_prior_prompts: $n_prior_prompts, session_id: $session_id}')
else
  proxy_payload=$(jq -cn \
    --argjson similarity "$max_sim" \
    --argjson n_prior_prompts "$n_prior" \
    '{similarity: $similarity, n_prior_prompts: $n_prior_prompts}')
fi

outcome_proxies::emit_event retry "$proxy_payload" || true
exit 0
