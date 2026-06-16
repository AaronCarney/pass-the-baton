#!/usr/bin/env bash
# lib/transcript.sh - per-turn token stream from a Claude Code transcript JSONL.
# CC8: reads ONLY usage numeric fields. Never reads content/tools/results.

transcript::turn_stream() {
  local path="$1"
  [ -f "$path" ] || return 0
  jq -rR '
    (fromjson? // empty)
    | select(.type == "assistant")
    | .message.usage
    | if . == null then empty else
      [ (.cache_read_input_tokens // 0),
        ( if (.ephemeral_5m_input_tokens != null or .ephemeral_1h_input_tokens != null)
          then (.ephemeral_5m_input_tokens // 0)
          else (.cache_creation_input_tokens // 0) end ),
        (.ephemeral_1h_input_tokens // 0),
        (.input_tokens // 0),
        (.output_tokens // 0)
      ] | @tsv
    end
  ' "$path" 2>/dev/null || true
}

# transcript::ctx_out_stream <transcript_path>
#   Projects `transcript::turn_stream` output (5 cols: cache_read | cache_creation |
#   ephemeral_1h | input_tokens | output_tokens) to the 2-column shape that
#   `cost_model_none::trajectory_cost` expects: <ctx>\t<output_tokens>.
#   Per L0 §A2, the no-management arm bills `input_tokens` (column 4) as ctx at
#   base_in - full input is billed each turn (no cache discount in the no-mgmt arm).
#   COVENANT: this helper AND the fallback awk inside `replay_harness::compact_total`
#   (which uses `transcript::turn_stream | awk '{print $4}'`) both pin column 4 as
#   input_tokens. If `transcript::turn_stream`'s column layout ever changes, BOTH
#   consumers must move in lockstep.
transcript::ctx_out_stream() {
  local path="$1"
  [ -f "$path" ] || return 0
  transcript::turn_stream "$path" 2>/dev/null | awk -F'\t' 'BEGIN{OFS="\t"} { print $4, $5 }'
}

# transcript::clear_events <transcript_path>
#   Emits 0-indexed turn numbers (one per line) AFTER which a `/clear` event
#   was issued by the user. A turn is counted as an assistant message.
#   Empty output = no /clear events. CC8: reads only `type` and `content` text
#   for the substring match; emits only numerics.
transcript::clear_events() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk '
    /"type":"assistant"/ { turn++ }
    /"type":"user"/ && /"\/clear"/ { if (turn > 0) print (turn - 1) }
  ' "$path"
}

# transcript::compact_events <transcript_path>
#   Emits 0-indexed turn numbers (one per line) AFTER which a compact boundary
#   occurred. Detection: lines with `"compact_boundary":true` OR system messages
#   matching `isCompactSummary` (Claude Code transcript marker for auto-compact).
#   Empty output = no compact boundaries. CC8: reads only structural markers,
#   no prompt text.
transcript::compact_events() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk '
    /"type":"assistant"/ { turn++ }
    /"compact_boundary"[[:space:]]*:[[:space:]]*true/ ||
    /"isCompactSummary"[[:space:]]*:[[:space:]]*true/ {
      if (turn > 0) print (turn - 1)
    }
  ' "$path"
}
