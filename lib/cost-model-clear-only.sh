#!/usr/bin/env bash
# lib/cost-model-clear-only.sh - /clear-only arm cost model.
# Pure: no I/O, no jq, no per-turn arithmetic (per CC1). No rate-table dependency.
# Per L0 A2: summary_cost = 0. Caller treats post-/clear context as cold-cache.
set -u

# cost_model_clear_only::event_cost - USD float for a single /clear event.
# Always 0: /clear does no summary write, no API call beyond the user keystroke.
cost_model_clear_only::event_cost() {
  printf '%s\n' '0.000000'
}

# cost_model_clear_only::post_clear_cache_state
#   Emits the cache-state label to pass to cost_models::cost_of_turn for the
#   FIRST turn after a /clear boundary. Always emits "cold".
#
#   Implicit contract (callers MUST follow when constructing the next cost_of_turn call):
#     - cache_read = 0          (no preserved cache)
#     - cache_write_5m = 0      (caller decides whether to begin a new cache window;
#                                if a new prefix is established, separate cache-write
#                                surcharge applies - that's NOT part of /clear-only)
#     - cache_write_1h = 0
#     - fresh_input MUST include Sys (system prompt) tokens - system-prompt re-priming
#       applies because /clear destroys the entire conversation cache, including Sys.
#
#   Always returns rc=0; no error paths.
cost_model_clear_only::post_clear_cache_state() {
  printf '%s\n' 'cold'
}
