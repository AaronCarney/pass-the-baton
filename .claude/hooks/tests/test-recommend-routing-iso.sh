#!/usr/bin/env bash
# test-recommend-routing-iso.sh - standalone lib-level routing test.
# Sources lib/time-to-complete.sh directly (NO production CLI envelope).
# Tests time_to_complete::infer_method on three inline transcript fixtures:
#   transcript-1: compaction-fired event → 'compact'
#   transcript-2: /clear event          → 'clear-only'
#   transcript-3: neither               → 'none'
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# Source the lib directly - no production CLI wrapper
source "$REPO/lib/transcript.sh"
source "$REPO/lib/subset-stratify.sh"
source "$REPO/lib/time-to-complete.sh"

# ── Setup temp fixtures via heredocs ──
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# transcript-1: compaction fired via compact_boundary marker
cat > "$TMP/transcript-1.jsonl" <<'SESS'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":50}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}
{"type":"user","message":{"content":"world"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":30}}}
SESS

# transcript-2: /clear event used - content must be exactly "/clear" for awk pattern match
# transcript::clear_events uses: /"\/clear"/ which matches the literal bytes "/clear"
cat > "$TMP/transcript-2.jsonl" <<'SESS'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":50}}}
{"type":"user","message":{"content":"/clear"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20}}}
SESS

# transcript-3: neither compact boundary nor /clear
cat > "$TMP/transcript-3.jsonl" <<'SESS'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":50}}}
{"type":"user","message":{"content":"world"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":800,"output_tokens":40}}}
SESS

# ── Assert method inference ──
m1=$(time_to_complete::infer_method "$TMP/transcript-1.jsonl")
[ "$m1" = "compact" ] && _pass "transcript-1 infer_method==compact" \
  || _fail "transcript-1 infer_method==compact (got: $m1)"

m2=$(time_to_complete::infer_method "$TMP/transcript-2.jsonl")
[ "$m2" = "clear-only" ] && _pass "transcript-2 infer_method==clear-only" \
  || _fail "transcript-2 infer_method==clear-only (got: $m2)"

m3=$(time_to_complete::infer_method "$TMP/transcript-3.jsonl")
[ "$m3" = "none" ] && _pass "transcript-3 infer_method==none" \
  || _fail "transcript-3 infer_method==none (got: $m3)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf 'ROUTING_ISO_OK\n'
