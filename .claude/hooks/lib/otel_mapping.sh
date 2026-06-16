#!/bin/bash
# OTel field rename table for checkpoint event export.
# Applied ONLY when exporting (e.g., BATON_OTEL_EXPORT=1 piped through this fn).
# Never touches disk records - pure in-memory transform per Brief 3 §5 (v1.40.0).
#
# Mapping (data.* → OTel gen_ai.*):
#   provider    → gen_ai.provider.name
#   model       → gen_ai.request.model
#   tokens_in   → gen_ai.usage.input_tokens
#   tokens_out  → gen_ai.usage.output_tokens
#   tool_name   → gen_ai.tool.name
#   session_id  → gen_ai.conversation.id
#
# Policy: unknown data.* keys pass through unchanged (additive). Top-level
# envelope fields (schema, schema_version, ts, event) are not renamed.

# Public: otel::rename_line "<json_line>" - outputs the line with data.* keys renamed.
otel::rename_line() {
  local line="$1"
  printf '%s' "$line" | jq -c '
    . as $root
    | ($root.data // {}) as $d
    | {
        "gen_ai.provider.name":        "provider",
        "gen_ai.request.model":        "model",
        "gen_ai.usage.input_tokens":   "tokens_in",
        "gen_ai.usage.output_tokens":  "tokens_out",
        "gen_ai.tool.name":            "tool_name",
        "gen_ai.conversation.id":      "session_id"
      } as $map
    | ($map | to_entries | map(.value) ) as $sources
    | ($map
        | to_entries
        | map(select($d[.value] != null) | {key: .key, value: $d[.value]})
        | from_entries
      ) as $renamed
    | ($d | with_entries(select(.key as $k | $sources | index($k) | not))) as $kept
    | $root | .data = ($kept + $renamed)
  '
}
