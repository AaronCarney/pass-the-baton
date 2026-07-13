#!/bin/bash
# usage-tokens.sh - shared extractor for the five-field token breakdown.
# Sourced by hooks (post-tool-batch.sh, post-subagent-cost.sh); not executed.
#
# Single source of truth for parsing an `assistant.message.usage` JSON into
# the per-run token fields, so every cost reader agrees on the same transcript.
# The jq here is byte-identical to the precedence formerly inlined in
# post-tool-batch.sh and must match tools/cost.sh's extractor verbatim.
#
# Contract - usage_tokens::extract <usage_json>:
#   Echoes ONE line, tab-separated, five integers in this order:
#     cache_read \t cache_write_5m \t cache_write_1h \t fresh_input \t output
#   Precedence for cache_write_5m: when either ephemeral_5m_input_tokens or
#   ephemeral_1h_input_tokens is present, use ephemeral_5m_input_tokens (the
#   flat cache_creation_input_tokens is ignored); otherwise fall back to the
#   flat cache_creation_input_tokens. All fields default to 0 when absent.
#   Consume with:
#     IFS=$'\t' read -r cache_read cache_write_5m cache_write_1h \
#       fresh_input output < <(usage_tokens::extract "$usage_json")

: "${_TRANSCRIPT_SCAN_LINES:=50}"   # transcript tail window (lines) scanned for usage/model/turn

usage_tokens::extract() {
  local usage_json="$1"
  local cache_read cache_write_5m cache_write_1h fresh_input output
  cache_read=$(printf '%s' "$usage_json" | jq -r '.cache_read_input_tokens // 0')
  cache_write_5m=$(printf '%s' "$usage_json" | jq -r '
    if (.ephemeral_5m_input_tokens != null or .ephemeral_1h_input_tokens != null) then
      (.ephemeral_5m_input_tokens // 0)
    else
      (.cache_creation_input_tokens // 0)
    end')
  cache_write_1h=$(printf '%s' "$usage_json" | jq -r '.ephemeral_1h_input_tokens // 0')
  fresh_input=$(printf '%s' "$usage_json" | jq -r '.input_tokens // 0')
  output=$(printf '%s' "$usage_json" | jq -r '.output_tokens // 0')
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cache_read" "$cache_write_5m" "$cache_write_1h" "$fresh_input" "$output"
}
