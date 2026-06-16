#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
source "$REPO/lib/config.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME/baton"
CFG="$XDG_CONFIG_HOME/baton/config.json"
PASS=0; FAIL=0
_aeq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# Case 1: no env, no config file, returns default.
rm -f "$CFG"
unset BATON_PCT_THRESHOLD
_aeq '23' "$(_cfg::get BATON_PCT_THRESHOLD 23)" 'default when nothing set'

# Case 2: no env, value in config.json, returns config value.
echo '{"BATON_PCT_THRESHOLD":"35"}' > "$CFG"
unset BATON_PCT_THRESHOLD
_aeq '35' "$(_cfg::get BATON_PCT_THRESHOLD 23)" 'config value when env unset'

# Case 3: env wins over config - explicit baseline comparison.
unset BATON_PCT_THRESHOLD
_aeq '35' "$(_cfg::get BATON_PCT_THRESHOLD 23)" '3a: env unset + config=35 → 35'
export BATON_PCT_THRESHOLD=50
_aeq '50' "$(_cfg::get BATON_PCT_THRESHOLD 23)" '3b: env=50 beats config=35'
unset BATON_PCT_THRESHOLD

# Case 4: missing key in config + no env returns default.
_aeq 'fallback' "$(_cfg::get BATON_DOES_NOT_EXIST fallback)" 'missing key falls to default'

# Case 5: config value literally null → falls to default.
echo '{"BATON_PCT_THRESHOLD":null}' > "$CFG"
_aeq '23' "$(_cfg::get BATON_PCT_THRESHOLD 23)" 'JSON null → default'

# Case 6: malformed config.json → falls to default, no crash.
echo 'not valid json {{{' > "$CFG"
_aeq '23' "$(_cfg::get BATON_PCT_THRESHOLD 23)" 'malformed config → default (jq error swallowed)'

# Case 7: explicit config_key arg - env name differs from persisted JSON key.
echo '{"threshold_pct":"42"}' > "$CFG"
unset BATON_PCT_THRESHOLD
_aeq '42' "$(_cfg::get BATON_PCT_THRESHOLD 23 threshold_pct)" '7a: reads lowercase config_key'
export BATON_PCT_THRESHOLD=50
_aeq '50' "$(_cfg::get BATON_PCT_THRESHOLD 23 threshold_pct)" '7b: env still wins over config_key'
unset BATON_PCT_THRESHOLD
echo '{"BATON_PCT_THRESHOLD":"99"}' > "$CFG"
_aeq '23' "$(_cfg::get BATON_PCT_THRESHOLD 23 threshold_pct)" '7c: uppercase key ignored when config_key given'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
