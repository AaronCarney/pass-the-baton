#!/usr/bin/env bash
# CC6: cost-model keys honor config.json via _cfg::get.
# shellcheck disable=SC1090,SC1091,SC2034  # dynamic source-under-test; loop counter intentional
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TOK="$REPO/lib/tokens.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
CFG="$XDG_CONFIG_HOME/baton/config.json"
PASS=0; FAIL=0
_aeq(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: exp %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# BATON_TOKEN_RATIOS: tokens::load_ratios sources the file the key points at.
# Prove config selects a ratios override file (set BYTES_PER_TOKEN_DEFAULT) that load_ratios then sources.
cat > "$TMP/ratios.sh" <<'RZ'
BYTES_PER_TOKEN_DEFAULT=10.0
RZ
echo "{\"BATON_TOKEN_RATIOS\":\"$TMP/ratios.sh\"}" > "$CFG"
out=$( unset BATON_TOKEN_RATIOS BATON_COST_MODEL; source "$TOK"; tokens::load_ratios; echo "$BYTES_PER_TOKEN_DEFAULT" )
_aeq '10.0' "$out" 'TOKEN_RATIOS file from config is sourced'

# BATON_COST_MODEL via config changes the Opus multiplier branch.
# default (sonnet): no multiplier -> estimate(3200 bytes, code, ratio 3.2) = 1000
echo '{}' > "$CFG"
_aeq 1000 "$( unset BATON_COST_MODEL; source "$TOK"; tokens::estimate 3200 code )" 'COST_MODEL default sonnet, no opus mult'
# config opus-4-7 -> code mult 1.20 -> 1200
echo '{"BATON_COST_MODEL":"claude-opus-4-7"}' > "$CFG"
_aeq 1200 "$( unset BATON_COST_MODEL; source "$TOK"; tokens::estimate 3200 code )" 'COST_MODEL opus from config applies multiplier'
_aeq 1000 "$( export BATON_COST_MODEL=claude-sonnet-4-6; source "$TOK"; tokens::estimate 3200 code )" 'COST_MODEL env wins (sonnet)'

# HARD-FALLBACK for tokens.sh (sibling config.sh unreachable)
ISO="$TMP/iso/lib"; mkdir -p "$ISO"; cp "$TOK" "$ISO/"
echo '{"BATON_COST_MODEL":"claude-opus-4-7"}' > "$CFG"
_aeq 1200 "$( unset -f _cfg::get 2>/dev/null; unset BATON_COST_MODEL; source "$ISO/tokens.sh"; tokens::estimate 3200 code )" 'tokens.sh hard-fallback honors config'

# BATON_SUMMARY_MODEL via cost-compare.sh --json. NB: --json exits early (rc 0, no stdout) at
# cost-compare.sh:88 'no assistant turns in transcript' UNLESS a transcript with assistant turns
# is supplied, so a fixture is mandatory. summary_model is emitted at cost-compare.sh:141.
# claude-haiku-4-5 is in the price table (lib/cost-models.sh:48) so the cost_of_turn guard (:79) passes.
FIX="$TMP/cc-fixture.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"x"}}'
  echo '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":18000,"input_tokens":500,"output_tokens":1500}}}'
  for i in 1 2 3 4; do
    echo '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"cache_read_input_tokens":18000,"input_tokens":500,"output_tokens":1500}}}'
  done
} > "$FIX"
echo '{"BATON_SUMMARY_MODEL":"claude-haiku-4-5"}' > "$CFG"
out=$( unset BATON_SUMMARY_MODEL; bash "$REPO/tools/cost-compare.sh" --transcript "$FIX" --json 2>/dev/null | jq -r '.summary_model // empty' )
_aeq 'claude-haiku-4-5' "$out" 'SUMMARY_MODEL from config surfaces in cost-compare --json'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
