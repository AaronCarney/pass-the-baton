#!/usr/bin/env bash
# CC6: prove every migrated workstream-lib.sh consumer honors config.json (env > config.json > default),
# and that the inline hard-fallback still honors config.json when lib/config.sh is unreachable.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
WL="$REPO/.claude/hooks/lib/workstream-lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/baton"
CFG="$XDG_CONFIG_HOME/baton/config.json"
PASS=0; FAIL=0
_aeq(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: exp %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# threshold (cfg_key=threshold_pct)
echo '{}' > "$CFG"
_aeq 20 "$( source "$WL"; printf '%s' "$BATON_DEFAULT_PCT_THRESHOLD" )" 'canonical constant BATON_DEFAULT_PCT_THRESHOLD is 20'
_aeq "$( source "$WL"; printf '%s' "$BATON_DEFAULT_PCT_THRESHOLD" )" "$( unset BATON_PCT_THRESHOLD; source "$WL"; checkpoint_threshold )" 'checkpoint_threshold default derives from the constant (single-source)'
_aeq 20 "$( unset BATON_PCT_THRESHOLD; source "$WL"; checkpoint_threshold )" 'threshold -> default (20)'
echo '{"threshold_pct":"40"}' > "$CFG"
_aeq 40 "$( unset BATON_PCT_THRESHOLD; source "$WL"; checkpoint_threshold )" 'threshold from config (legacy lowercase key)'
_aeq 55 "$( export BATON_PCT_THRESHOLD=55; source "$WL"; checkpoint_threshold )" 'threshold env beats config'

# threshold bounds validation (E-B): invalid / out-of-range -> default 20
echo '{}' > "$CFG"
_aeq 20 "$( export BATON_PCT_THRESHOLD=abc; source "$WL"; checkpoint_threshold )" 'threshold non-integer env -> default (20)'
_aeq 20 "$( export BATON_PCT_THRESHOLD=0;   source "$WL"; checkpoint_threshold )" 'threshold 0 (below range) -> default (20)'
_aeq 20 "$( export BATON_PCT_THRESHOLD=100; source "$WL"; checkpoint_threshold )" 'threshold 100 (above range) -> default (20)'
_aeq 20 "$( export BATON_PCT_THRESHOLD=-5;  source "$WL"; checkpoint_threshold )" 'threshold negative -> default (20)'
_aeq 1  "$( export BATON_PCT_THRESHOLD=1;   source "$WL"; checkpoint_threshold )" 'threshold lower bound 1 honored'
_aeq 99 "$( export BATON_PCT_THRESHOLD=99;  source "$WL"; checkpoint_threshold )" 'threshold upper bound 99 honored'
echo '{"threshold_pct":"250"}' > "$CFG"
_aeq 20 "$( unset BATON_PCT_THRESHOLD; source "$WL"; checkpoint_threshold )" 'threshold out-of-range config -> default (20)'

# tracking ttl (seconds = days*86400)
echo '{}' > "$CFG"
_aeq 604800 "$( unset BATON_TRACKING_TTL_DAYS; source "$WL"; tracking_ttl_seconds )" 'tracking ttl default 7d'
echo '{"BATON_TRACKING_TTL_DAYS":"5"}' > "$CFG"
_aeq 432000 "$( unset BATON_TRACKING_TTL_DAYS; source "$WL"; tracking_ttl_seconds )" 'tracking ttl from config'
_aeq 864000 "$( export BATON_TRACKING_TTL_DAYS=10; source "$WL"; tracking_ttl_seconds )" 'tracking ttl env wins'

# tmp ttl (minutes = hours*60)
echo '{}' > "$CFG"
_aeq 1440 "$( unset BATON_TMP_TTL_HOURS; source "$WL"; tmp_ttl_minutes )" 'tmp ttl default 24h'
echo '{"BATON_TMP_TTL_HOURS":"6"}' > "$CFG"
_aeq 360 "$( unset BATON_TMP_TTL_HOURS; source "$WL"; tmp_ttl_minutes )" 'tmp ttl from config'

# workstream ttl
echo '{}' > "$CFG"
_aeq 2592000 "$( unset BATON_WORKSTREAM_TTL_DAYS; source "$WL"; workstream_ttl_seconds )" 'workstream ttl default 30d'
echo '{"BATON_WORKSTREAM_TTL_DAYS":"2"}' > "$CFG"
_aeq 172800 "$( unset BATON_WORKSTREAM_TTL_DAYS; source "$WL"; workstream_ttl_seconds )" 'workstream ttl from config'

# archive_dir
echo '{}' > "$CFG"
_aeq "$HOME/.local/share/baton" "$( unset BATON_ARCHIVE_DIR; source "$WL"; archive_dir )" 'archive_dir default'
echo '{"BATON_ARCHIVE_DIR":"/x/arch"}' > "$CFG"
_aeq '/x/arch' "$( unset BATON_ARCHIVE_DIR; source "$WL"; archive_dir )" 'archive_dir from config'

# progress_dir (default depends on project arg; BATON_DIR unset)
echo '{}' > "$CFG"
_aeq '/proj/.baton/progress' "$( unset BATON_PROGRESS_DIR BATON_DIR; source "$WL"; checkpoint_progress_dir /proj )" 'progress_dir default'
echo '{"BATON_PROGRESS_DIR":"/x/prog"}' > "$CFG"
_aeq '/x/prog' "$( unset BATON_PROGRESS_DIR BATON_DIR; source "$WL"; checkpoint_progress_dir /proj )" 'progress_dir from config'

# display_name (cfg_key=display_name, default=caller fallback $3)
echo '{}' > "$CFG"
_aeq 'fallbk' "$( unset BATON_DISPLAY_NAME; source "$WL"; derive_display_name '' '' fallbk )" 'display_name fallback when neither'
echo '{"display_name":"WS-Cfg"}' > "$CFG"
_aeq 'WS-Cfg' "$( unset BATON_DISPLAY_NAME; source "$WL"; derive_display_name '' '' fallbk )" 'display_name from config (legacy lowercase)'
_aeq 'EnvName' "$( export BATON_DISPLAY_NAME=EnvName; source "$WL"; derive_display_name '' '' fallbk )" 'display_name env wins'

# BATON_DIR stays env-only by design (config must NOT override it)
echo '{"BATON_DIR":"/should/be/ignored"}' > "$CFG"
_aeq '/proj/.baton' "$( unset BATON_DIR; source "$WL"; checkpoint_dir /proj )" 'BATON_DIR is env-only (config ignored)'
_aeq '/env/dir' "$( export BATON_DIR=/env/dir; source "$WL"; checkpoint_dir /proj )" 'BATON_DIR honors env'

# HARD-FALLBACK: copy the file where ../../../lib/config.sh is unreachable -> inline fallback must still read config.json
ISO="$TMP/iso/.claude/hooks/lib"; mkdir -p "$ISO"; cp "$WL" "$ISO/"
echo '{"threshold_pct":"77"}' > "$CFG"
_aeq 77 "$( unset -f _cfg::get 2>/dev/null; unset BATON_PCT_THRESHOLD; source "$ISO/workstream-lib.sh"; checkpoint_threshold )" 'hard-fallback honors config when lib/config.sh unreachable'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
