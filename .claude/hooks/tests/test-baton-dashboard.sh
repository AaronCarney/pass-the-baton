#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
DASH="$REPO/tools/baton-dashboard.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/cfg"
mkdir -p "$XDG_CONFIG_HOME/baton"
export BATON_DIR="$TMP/.baton"
mkdir -p "$BATON_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
PASS=0; FAIL=0
_aeq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }
_acontains() { case "$1" in *"$2"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); printf 'FAIL: %q not found in output (%s)\n' "$2" "${3:-}" >&2;; esac; }

# Case A: show prints every documented key.
show_out=$(bash "$DASH" show)
for key in template threshold_pct display_name templates_dir project_context_file \
           BATON_DIR BATON_PROGRESS_DIR BATON_ARCHIVE_DIR BATON_PROJECT_DIR \
           BATON_WORKSTREAM_TTL_DAYS BATON_TRACKING_TTL_DAYS BATON_TMP_TTL_HOURS \
           BATON_COLLECT BATON_TIMING BATON_OUTCOME_PROXIES BATON_PREWARM BATON_EVENT_LOG_DISABLE \
           BATON_EVENT_LOG BATON_OTEL_EXPORT \
           BATON_COST_MODEL BATON_SUMMARY_MODEL BATON_TOKEN_RATIOS \
           BATON_STATUSLINE_COLOR_MODE; do
  _acontains "$show_out" "$key" "$key in show"
done

# Case A2: group-header ordering - Paths group precedes TTLs precedes Opt-ins.
P_LINE=$(printf '%s\n' "$show_out" | grep -n 'BATON_DIR' | head -1 | cut -d: -f1)
T_LINE=$(printf '%s\n' "$show_out" | grep -n 'BATON_WORKSTREAM_TTL_DAYS' | head -1 | cut -d: -f1)
O_LINE=$(printf '%s\n' "$show_out" | grep -n 'BATON_TIMING' | head -1 | cut -d: -f1)
[ -n "$P_LINE" ] && [ -n "$T_LINE" ] && [ -n "$O_LINE" ] && [ "$P_LINE" -lt "$T_LINE" ] && [ "$T_LINE" -lt "$O_LINE" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: group ordering Paths<TTLs<Opt-ins: $P_LINE,$T_LINE,$O_LINE" >&2; }

# Iter-4: assert each of the six group headers appears literally in show output.
_acontains "$show_out" '[Existing]' 'Existing header present'
_acontains "$show_out" '[Paths]' 'Paths header present'
# Existing-group ordering anchor - [Existing] header must appear before the first [Paths] header.
E_LINE=$(printf '%s\n' "$show_out" | grep -n '\[Existing\]' | head -1 | cut -d: -f1)
PG_LINE=$(printf '%s\n' "$show_out" | grep -n '\[Paths\]' | head -1 | cut -d: -f1)
[ -n "$E_LINE" ] && [ -n "$PG_LINE" ] && [ "$E_LINE" -lt "$PG_LINE" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: [Existing] must precede [Paths] (E=$E_LINE PG=$PG_LINE)" >&2; }
_acontains "$show_out" '[TTLs]' 'TTLs header present'
_acontains "$show_out" '[Opt-ins]' 'Opt-ins header present'
_acontains "$show_out" '[Event-log]' 'Event-log header present'
_acontains "$show_out" '[Cost-model]' 'Cost-model header present'
_acontains "$show_out" '[Statusline]' 'Statusline header present'

# Case B: set rejects invalid color-mode.
set +e
out=$(bash "$DASH" set BATON_STATUSLINE_COLOR_MODE=rainbow 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: invalid color-mode should reject' >&2; }
_acontains "$out" 'color' 'error mentions color'

# Case C: set accepts valid color-mode + threshold + path + opt-in.
bash "$DASH" set BATON_STATUSLINE_COLOR_MODE=bands
bash "$DASH" set BATON_TIMING=1
bash "$DASH" set BATON_WORKSTREAM_TTL_DAYS=14
show_out=$(bash "$DASH" show)
_acontains "$show_out" 'bands' 'bands stored'
_acontains "$show_out" 'BATON_TIMING' 'opt-in stored'
_acontains "$show_out" '14' 'TTL stored'

# Case D: TTL must be non-negative integer.
set +e
bash "$DASH" set BATON_WORKSTREAM_TTL_DAYS=-1 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: negative TTL should reject' >&2; }

# Iter-4: whitespace-bearing TTL input. The validation regex `^[0-9]+$` rejects leading/trailing space.
set +e
bash "$DASH" set 'BATON_WORKSTREAM_TTL_DAYS= 14' >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: whitespace-bearing TTL should reject (parser does not auto-trim)' >&2; }

# Case E: opt-in must be 0 or 1.
set +e
bash "$DASH" set BATON_TIMING=on >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: non-binary opt-in should reject' >&2; }

# Case F: empty path values rejected for path keys.
set +e
bash "$DASH" set BATON_DIR= >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: empty BATON_DIR should reject' >&2; }

# Case G: unknown-key rejected by catch-all.
set +e
out=$(bash "$DASH" set BATON_NONEXISTENT=foo 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: unknown key should reject' >&2; }
_acontains "$out" 'Valid keys:' 'catch-all error includes Valid keys: header'
for key in template threshold_pct display_name templates_dir project_context_file \
           BATON_DIR BATON_PROGRESS_DIR BATON_ARCHIVE_DIR BATON_PROJECT_DIR \
           BATON_WORKSTREAM_TTL_DAYS BATON_TRACKING_TTL_DAYS BATON_TMP_TTL_HOURS \
           BATON_COLLECT BATON_TIMING BATON_OUTCOME_PROXIES BATON_PREWARM BATON_EVENT_LOG_DISABLE \
           BATON_EVENT_LOG BATON_OTEL_EXPORT \
           BATON_COST_MODEL BATON_SUMMARY_MODEL BATON_TOKEN_RATIOS \
           BATON_STATUSLINE_COLOR_MODE; do
  case "$out" in *"$key"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: catch-all error missing key $key" >&2;; esac
done

# Case H: cross-task contract - lib/config.sh _cfg::get reads dashboard-set template.
bash "$DASH" set template=free
actual=$(bash -c "source $REPO/lib/config.sh && _cfg::get template default")
_aeq 'free' "$actual" 'T4->T6 contract: dashboard set + lib/config.sh get integrate'

# Case I: KEY=VALUE parser must preserve `=` characters in VALUE.
bash "$DASH" set BATON_TOKEN_RATIOS=input=3,output=15
show_out=$(bash "$DASH" show)
_acontains "$show_out" 'input=3,output=15' 'BATON_TOKEN_RATIOS preserves equals signs in value'

# Case I2 (E23): BATON_COLLECT master switch - set 1/0 persist verbatim, invalid rejected.
bash "$DASH" set BATON_COLLECT=1 >/dev/null
_aeq '1' "$(jq -r '.BATON_COLLECT' "$XDG_CONFIG_HOME/baton/config.json")" 'BATON_COLLECT=1 persists'
bash "$DASH" set BATON_COLLECT=0 >/dev/null
_aeq '0' "$(jq -r '.BATON_COLLECT' "$XDG_CONFIG_HOME/baton/config.json")" 'BATON_COLLECT=0 persists'
set +e
bash "$DASH" set BATON_COLLECT=2 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: BATON_COLLECT=2 should reject (not 0|1)' >&2; }

# --- Retained legacy coverage (original 5-key behavior must not regress) ---

# Case J: set template=task persists to config.json.
bash "$DASH" set template=task >/dev/null 2>&1
_aeq 'task' "$(jq -r '.template' "$XDG_CONFIG_HOME/baton/config.json")" 'set template=task persists'

# Case K: unknown template rejected.
set +e
bash "$DASH" set template=bogus >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: unknown template should reject' >&2; }

# Case L: threshold_pct out of range rejected.
set +e
bash "$DASH" set threshold_pct=150 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: threshold_pct=150 should reject' >&2; }

# --- Session-scoped liveness guard (E4): the template switch blocks ONLY on THIS
# terminal's OWN owed checkpoint, resolved via the per-terminal parent-sid map
# (session-start.sh:207). Bind this terminal deterministically: a fixed
# CLAUDE_TERMINAL_ID makes term_hash reproducible so we can write the map entry
# the dashboard will read back.
export CLAUDE_TERMINAL_ID="dash-test-term-$$"
_myhash() { CLAUDE_TERMINAL_ID="$1" bash -c "source $REPO/.claude/hooks/lib/workstream-lib.sh && term_hash"; }
TH_SELF=$(_myhash "$CLAUDE_TERMINAL_ID")

# Case M (M6): template switch refused while THIS terminal's LIVE checkpoint is in
# flight. The parent-sid map binds the flag to this terminal; the pct sibling is
# what makes it live (without it this is a stale flag, ignored below).
m6_sid="dash-m6-$$"
echo "$m6_sid" > "/tmp/claude-parent-sid-${TH_SELF}"
touch "/tmp/baton-pending-${m6_sid}"
echo 42 > "/tmp/claude-context-pct-${m6_sid}"
set +e
out=$(bash "$DASH" set template=free 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${m6_sid}" "/tmp/claude-context-pct-${m6_sid}"
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: template switch should refuse while a live checkpoint is in flight' >&2; }
_acontains "$out" 'in flight' 'PENDING refusal message mentions in flight'

# A stale PENDING flag whose session is gone must not block a template switch.
# Liveness signal: the statusline rewrites /tmp/claude-context-pct-<sid> every
# turn, and cleanup-on-exit removes both files together on a clean exit. So a
# pending flag with no fresh pct sibling belongs to a dead session. Session-scoping
# makes this unconditional and attributable: the flag is THIS terminal's own.
stale_sid="dash-stale-$$"
echo "$stale_sid" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${stale_sid}"
set +e
out=$(bash "$DASH" set template=task 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${stale_sid}"
[ "$rc" = '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: stale PENDING flag should not block template switch (rc=$rc: $out)" >&2; }

# A LIVE checkpoint owed by THIS terminal must still block.
live_sid="dash-live-$$"
echo "$live_sid" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${live_sid}"
echo 42 > "/tmp/claude-context-pct-${live_sid}"
set +e
out=$(bash "$DASH" set template=free 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${live_sid}" "/tmp/claude-context-pct-${live_sid}"
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: live checkpoint should still block template switch' >&2; }

# A pct sibling OLDER than the TTL is not liveness - it is a dead session whose
# files have not been swept yet. This drives the find -mmin predicate itself,
# which no other case reaches.
old_sid="dash-old-$$"
echo "$old_sid" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${old_sid}"
touch -d '2 days ago' "/tmp/claude-context-pct-${old_sid}"
set +e
out=$(bash "$DASH" set template=task 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${old_sid}" "/tmp/claude-context-pct-${old_sid}"
[ "$rc" = '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: pct sibling older than the TTL should not count as live (rc=$rc: $out)" >&2; }

# M6-mode: the liveness WINDOW is mode-dependent, and this is the only case that
# exercises the auto_continue_mode branch. The same pending flag, with a pct
# sibling aged BETWEEN the short auto window (~15 min) and the long manual window
# (the /tmp TTL), must read DEAD under auto-continue and LIVE under manual. Drive
# the mode via the BATON_AUTO_CONTINUE_MODE env override (env outranks config in
# _cfg::get), so no fixture config.json edit is needed.
mode_sid="dash-mode-$$"
echo "$mode_sid" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${mode_sid}"
touch -d '30 minutes ago' "/tmp/claude-context-pct-${mode_sid}"
set +e
out=$(BATON_AUTO_CONTINUE_MODE=relaunch bash "$DASH" set template=task 2>&1); rc_auto=$?
out2=$(BATON_AUTO_CONTINUE_MODE=off      bash "$DASH" set template=free 2>&1); rc_manual=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${mode_sid}" "/tmp/claude-context-pct-${mode_sid}"
[ "$rc_auto" = '0' ]   && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: auto-continue mode should read a 30-min-old flag as dead (rc=$rc_auto: $out)" >&2; }
[ "$rc_manual" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: manual mode should read the same flag as live (rc=$rc_manual: $out2)" >&2; }

# Case (a): a DIFFERENT terminal's live flag must NOT block this terminal. The
# parent-sid map points at sid_self, but the live pending+pct pair belongs to
# sid_other. Pre-session-scoping this blocked (machine-wide glob); now it allows.
sid_self="dash-self-$$"; sid_other="dash-other-$$"
echo "$sid_self" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${sid_other}"
echo 42 > "/tmp/claude-context-pct-${sid_other}"
set +e
out=$(bash "$DASH" set template=task 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${sid_other}" "/tmp/claude-context-pct-${sid_other}"
[ "$rc" = '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: a different terminal's live flag must not block (rc=$rc: $out)" >&2; }

# Case (b): THIS terminal's live flag MUST block.
echo "$sid_self" > "/tmp/claude-parent-sid-${TH_SELF}"
echo 99 > "/tmp/baton-pending-${sid_self}"
echo 42 > "/tmp/claude-context-pct-${sid_self}"
set +e
out=$(bash "$DASH" set template=free 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_SELF}" "/tmp/baton-pending-${sid_self}" "/tmp/claude-context-pct-${sid_self}"
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: this terminal's live flag must block (rc=$rc: $out)" >&2; }
_acontains "$out" 'in flight' 'own-flag refusal message mentions in flight'

# Case (c): resume-reconnect must still block. A resumed session lands on a NEW
# term_hash (fresh CLAUDE_TERMINAL_ID) while the SAME session_id still owes; its
# session-start rewrites parent-sid for the new hash. Running the dashboard under
# the new terminal id must resolve the resumed sid and block on its own owed
# checkpoint - proving the guard keys on session_id, not term_hash.
sid_resumed="dash-resume-$$"
TERM_RESUME="dash-test-term-resume-$$"
TH_RESUME=$(_myhash "$TERM_RESUME")
echo "$sid_resumed" > "/tmp/claude-parent-sid-${TH_RESUME}"
echo 99 > "/tmp/baton-pending-${sid_resumed}"
echo 42 > "/tmp/claude-context-pct-${sid_resumed}"
set +e
out=$(CLAUDE_TERMINAL_ID="$TERM_RESUME" bash "$DASH" set template=task 2>&1); rc=$?
set -e
rm -f "/tmp/claude-parent-sid-${TH_RESUME}" "/tmp/baton-pending-${sid_resumed}" "/tmp/claude-context-pct-${sid_resumed}"
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: resume-reconnect must still block its own owed checkpoint (rc=$rc: $out)" >&2; }

# Case N: legacy-key set→show round-trip (regression - env-name vs config-key mismatch).
# These keys persist under lowercase config keys but show read them via the uppercase
# env name; verify the set value is reflected back by show.
unset BATON_PCT_THRESHOLD BATON_DISPLAY_NAME 2>/dev/null || true
bash "$DASH" set threshold_pct=37 >/dev/null
bash "$DASH" set display_name=roundtrip-ws >/dev/null
n_out=$(bash "$DASH" show)
printf '%s\n' "$n_out" | grep -E '^[[:space:]]*threshold_pct:' | grep -q '37' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: show should reflect threshold_pct=37 after set" >&2; }
printf '%s\n' "$n_out" | grep -E '^[[:space:]]*display_name:' | grep -q 'roundtrip-ws' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: show should reflect display_name after set" >&2; }

# CC6 E-A: displayed defaults must equal consumer defaults (fresh config, no env).
rm -f "$XDG_CONFIG_HOME/baton/config.json"; echo '{}' > "$XDG_CONFIG_HOME/baton/config.json"
fresh=$( unset BATON_TRACKING_TTL_DAYS BATON_TMP_TTL_HOURS BATON_SUMMARY_MODEL BATON_EVENT_LOG BATON_TOKEN_RATIOS; bash "$DASH" show )
val_of(){ printf '%s\n' "$fresh" | sed -n "s/^[[:space:]]*$1[[:space:]]*//p" | sed -E 's/[[:space:]]*\[[a-z][a-z -]*\][[:space:]]*$//'; }
_aeq 7  "$(val_of 'BATON_TRACKING_TTL_DAYS:')" 'tracking ttl default shows 7'
_aeq 24 "$(val_of 'BATON_TMP_TTL_HOURS:')"     'tmp ttl default shows 24'
_aeq '' "$(val_of 'BATON_SUMMARY_MODEL:')"      'summary model default empty'
case "$(val_of 'BATON_EVENT_LOG:')" in */baton/hook-events.jsonl) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo 'FAIL: EVENT_LOG default should be XDG state path' >&2;; esac
case "$(val_of 'BATON_TOKEN_RATIOS:')" in */baton/token-ratios.sh) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo 'FAIL: TOKEN_RATIOS default should be the ratios path' >&2;; esac

# E-C: set still round-trips after routing through _cfg::set
CFG="$XDG_CONFIG_HOME/baton/config.json"
bash "$DASH" set threshold_pct=44 >/dev/null 2>&1
_aeq 44 "$(jq -r '.threshold_pct' "$CFG")" 'threshold_pct set persists (number)'
_aeq number "$(jq -r '.threshold_pct|type' "$CFG")" 'threshold_pct stored as JSON number'
bash "$DASH" set display_name=hi >/dev/null 2>&1
_aeq string "$(jq -r '.display_name|type' "$CFG")" 'string key stored as JSON string'
if jq -e . "$CFG" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo 'FAIL: config.json valid after dashboard sets' >&2; fi
# E-C: the now-false 'telemetry only / fixed 23%' note must be gone (honesty fix)
if ! bash "$DASH" show 2>/dev/null | grep -qi 'fixed 23'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo 'FAIL: show note no longer claims fixed-23 trigger' >&2; fi
if ! bash "$DASH" show 2>/dev/null | grep -qi 'telemetry only'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo 'FAIL: show note no longer claims telemetry-only' >&2; fi

# === E3: effective-source tags + honesty ===
# ES1: an unset key shows [default].
rm -f "$XDG_CONFIG_HOME/baton/config.json"
es_out=$(bash "$DASH" show)
_acontains "$es_out" '[default]' 'a default-sourced key shows [default]'
# Row-scoped tag assertion helper: the tag must be on the SAME line as the key,
# not merely somewhere in the multi-row output.
_row_has(){ printf '%s\n' "$1" | grep -E "^[[:space:]]*$2:" | grep -qF -- "$3"; }
_row_lacks(){ ! _row_has "$1" "$2" "$3"; }
# ES2: a config-set key (env==config name) shows [config] on its own row.
bash "$DASH" set BATON_WORKSTREAM_TTL_DAYS=14 >/dev/null
es_out=$(bash "$DASH" show)
_row_has "$es_out" 'BATON_WORKSTREAM_TTL_DAYS' '[config]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: config-set key should show [config]' >&2; }
# ES3: an env-overridden key shows [env].
es_out=$(BATON_WORKSTREAM_TTL_DAYS=99 bash "$DASH" show)
_row_has "$es_out" 'BATON_WORKSTREAM_TTL_DAYS' '[env]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: env-set key should show [env]' >&2; }
# ES3b: a config-set LEGACY key (env name != config key) shows [config] via the two-arg _src path.
bash "$DASH" set threshold_pct=37 >/dev/null
es_out=$(bash "$DASH" show)
_row_has "$es_out" 'threshold_pct' '[config]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: config-set legacy key threshold_pct should show [config]' >&2; }
# ES3c: same legacy key, env override -> [env] (two-arg _src honors env first).
es_out=$(BATON_PCT_THRESHOLD=41 bash "$DASH" show)
_row_has "$es_out" 'threshold_pct' '[env]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: env-set legacy key threshold_pct should show [env]' >&2; }
# ES7/ES8/ES9: the 3 config-only keys show a fixed [config-only] tag, NEVER [env], and
# their VALUE column must not reflect the exported (inert) env var.
es_out=$(BATON_TEMPLATES_DIR=/tmp/leakxx BATON_PROJECT_CONTEXT_FILE=/tmp/leakyy template=leakzz bash "$DASH" show)
_row_has "$es_out" 'templates_dir' '[config-only]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: templates_dir must show [config-only]' >&2; }
_row_lacks "$es_out" 'templates_dir' '[env]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: templates_dir must NOT show [env]' >&2; }
_row_lacks "$es_out" 'templates_dir' '/tmp/leakxx' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: templates_dir value must not reflect the inert env var' >&2; }
_row_has "$es_out" 'project_context_file' '[config-only]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: project_context_file must show [config-only]' >&2; }
_row_lacks "$es_out" 'project_context_file' '[env]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: project_context_file must NOT show [env]' >&2; }
_row_lacks "$es_out" 'project_context_file' '/tmp/leakyy' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: project_context_file value must not reflect the inert env var' >&2; }
_row_has "$es_out" 'template' '[config-only]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: template must show [config-only]' >&2; }
_row_lacks "$es_out" 'template' '[env]' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: template must NOT show [env] (selector is config-direct)' >&2; }
# ES7b/ES8b/ES9b: positive value assertion - the config-only VALUE column reflects the
# config.json value (guards the newly config-direct read from silently showing empty; a
# broken jq read that returned '' would pass every negative assert above).
bash "$DASH" set templates_dir=/tmp/cfgdir >/dev/null
bash "$DASH" set project_context_file=/tmp/cfgctx >/dev/null
mkdir -p "$XDG_CONFIG_HOME/baton/templates"; : > "$XDG_CONFIG_HOME/baton/templates/custom-tpl.md"
bash "$DASH" set template=custom-tpl >/dev/null
es_out=$(bash "$DASH" show)
_row_has "$es_out" 'templates_dir' '/tmp/cfgdir' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: templates_dir value column must show the config value' >&2; }
_row_has "$es_out" 'project_context_file' '/tmp/cfgctx' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: project_context_file value column must show the config value' >&2; }
_row_has "$es_out" 'template' 'custom-tpl' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: template value column must show the config value' >&2; }
# ES4: the two locator keys are tagged env-only by design.
es_out=$(bash "$DASH" show)
_row_has "$es_out" 'BATON_DIR' 'env-only by design' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: BATON_DIR must show env-only-by-design tag' >&2; }
_row_has "$es_out" 'BATON_PROJECT_DIR' 'env-only by design' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: BATON_PROJECT_DIR must show env-only-by-design tag' >&2; }
# ES5: the stale env-only-CLIs claim is GONE.
case "$es_out" in *'read env-only'*|*'query.sh'*) FAIL=$((FAIL+1)); echo 'FAIL: stale env-only-CLIs footnote still present' >&2;; *) PASS=$((PASS+1));; esac
# ES6: no 'interactive' claim in the usage/help text.
help_out=$(bash "$DASH" bogus-cmd 2>&1 || true); head_out=$(head -8 "$DASH")
case "$head_out" in *interactive*) FAIL=$((FAIL+1)); echo 'FAIL: interactive claim still in usage comment' >&2;; *) PASS=$((PASS+1));; esac

# === E4: single-sourced threshold default + helper-driven TTL rows ===
echo '{}' > "$CFG"
e4_fresh=$( unset BATON_PCT_THRESHOLD BATON_WORKSTREAM_TTL_DAYS BATON_TRACKING_TTL_DAYS BATON_TMP_TTL_HOURS; bash "$DASH" show )
e4_val(){ printf '%s\n' "$e4_fresh" | sed -n "s/^[[:space:]]*$1[[:space:]]*//p" | sed -E 's/[[:space:]]*\[[a-z][a-z -]*\][[:space:]]*$//'; }
_aeq 20 "$(e4_val 'threshold_pct:')" 'threshold default row shows 20 (from constant)'
_aeq 30 "$(e4_val 'BATON_WORKSTREAM_TTL_DAYS:')" 'workstream ttl default row shows 30 (from helper)'
_aeq 7  "$(e4_val 'BATON_TRACKING_TTL_DAYS:')" 'tracking ttl default row shows 7 (from helper)'
_aeq 24 "$(e4_val 'BATON_TMP_TTL_HOURS:')" 'tmp ttl default row shows 24 (from helper)'
# Footnote single-sources the bounds fallback to the constant (not a literal 23).
! bash "$DASH" show 2>/dev/null | grep -q 'else 23' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: footnote still hardcodes else 23' >&2; }

# === launch_alias + tmux-knob retrofit + display-honesty ===

# show surfaces the new rows.
show_out=$(bash "$DASH" show)
for k in launch_alias BATON_AUTO_CONTINUE_NUDGE BATON_AUTO_CONTINUE_LOG BATON_AUTO_CONTINUE_BIN; do
  _acontains "$show_out" "$k" "$k row present"
done

# launch_alias valid: persists + writes the marker block to the sandbox rc.
rm -f "$HOME/.bashrc"
bash "$DASH" set launch_alias=mybaton >/dev/null
_aeq mybaton "$(jq -r '.launch_alias' "$XDG_CONFIG_HOME/baton/config.json")" 'launch_alias persisted'
ok_block=$(grep -c 'baton launch alias' "$HOME/.bashrc" 2>/dev/null || echo 0)
[ "$ok_block" -ge 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: launch_alias should write rc marker block' >&2; }
grep -qE "alias mybaton='bash .*/tools/baton-run.sh'" "$HOME/.bashrc" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: rc alias mybaton target must be tools/baton-run.sh' >&2; }

# launch_alias invalid (builtin) rejected with a reason.
set +e
out=$(bash "$DASH" set launch_alias=cd 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: launch_alias=cd (builtin) should reject' >&2; }
_acontains "$out" 'builtin' 'reject reason names builtin'

# launch_alias empty (rc1) rejected with the empty reason.
set +e
out=$(bash "$DASH" set launch_alias= 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: launch_alias= (empty) should reject' >&2; }
_acontains "$out" 'cannot be empty' 'empty reject reason names cannot be empty'

# launch_alias keyword (rc4) rejected with the keyword reason.
set +e
out=$(bash "$DASH" set launch_alias=for 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: launch_alias=for (keyword) should reject' >&2; }
_acontains "$out" 'keyword' 'keyword reject reason names keyword'

# launch_alias that resolves on PATH (rc5 shadow) rejected - reachable after the sentinel
# fix (the previously-persisted alias is the reclaim sentinel, not the new value).
set +e
out=$(bash "$DASH" set launch_alias=ls 2>&1); rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: launch_alias=ls (PATH shadow) should reject' >&2; }
_acontains "$out" 'resolves on PATH' 'shadow reject reason names PATH'

# tmux-knob retrofit: set persists via config.json.
bash "$DASH" set BATON_AUTO_CONTINUE_NUDGE=go >/dev/null
_aeq go "$(jq -r '.BATON_AUTO_CONTINUE_NUDGE' "$XDG_CONFIG_HOME/baton/config.json")" 'NUDGE persisted'
# Config-honesty: the dashboard-set value resolves through _cfg::get the way the injector
# (tools/baton-auto-continue.sh) now reads it - persisted AND honored, not just persisted.
resolved=$(unset BATON_AUTO_CONTINUE_NUDGE; source "$REPO/lib/config.sh"; _cfg::get BATON_AUTO_CONTINUE_NUDGE proceed)
_aeq go "$resolved" 'config.json NUDGE honored by _cfg::get (injector resolution)'
grep -q '_cfg::get BATON_AUTO_CONTINUE_NUDGE' "$REPO/tools/baton-auto-continue.sh" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: injector must resolve NUDGE via _cfg::get' >&2; }
# Config-honesty (execution): the config.json-set NUDGE must reach the injector's actual
# `tmux send-keys -l` output, not merely resolve via _cfg::get. Run the real injector against
# a fake tmux shim that reports a ready pane and records the literal text it sends.
_shimdir="$TMP/tmuxshim"; mkdir -p "$_shimdir"
cat > "$_shimdir/tmux" <<'SHIM'
#!/usr/bin/env bash
sub="$1"; shift
if [ "$sub" = capture-pane ]; then printf 'ready$ \n'; exit 0; fi
if [ "$sub" = send-keys ]; then
  _lit=0; _last=""
  for _a in "$@"; do [ "$_a" = "-l" ] && _lit=1; _last="$_a"; done
  [ "$_lit" = 1 ] && printf '%s\n' "$_last" >> "$NUDGE_REC"
fi
exit 0
SHIM
chmod +x "$_shimdir/tmux"
bash "$DASH" set BATON_AUTO_CONTINUE_NUDGE=go >/dev/null
NUDGE_REC="$TMP/nudge.rec"; : > "$NUDGE_REC"
_donef="$TMP/done.flag"; : > "$_donef"
(
  export PATH="$_shimdir:$PATH" NUDGE_REC BATON_AUTO_CONTINUE=1
  unset BATON_AUTO_CONTINUE_NUDGE
  _AUTO_CONTINUE_POLL_INTERVAL=0.01 _AUTO_CONTINUE_POLL_MAX_SECONDS=2 \
    bash "$REPO/tools/baton-auto-continue.sh" nudge-exec-$$ "$_donef" '%9' >/dev/null 2>&1
)
grep -qx go "$NUDGE_REC" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: injector must send config.json NUDGE (go) verbatim to tmux' >&2; }

set +e
bash "$DASH" set BATON_AUTO_CONTINUE_LOG= >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != '0' ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: empty NUDGE/LOG should reject' >&2; }

# Display-honesty: a config.json BATON_DIR value must NOT surface in show (env-only consumer).
jq '.BATON_DIR="/tmp/leak-dir"' "$XDG_CONFIG_HOME/baton/config.json" > "$TMP/c.json" && mv "$TMP/c.json" "$XDG_CONFIG_HOME/baton/config.json"
hon=$(unset BATON_DIR; bash "$DASH" show)
case "$hon" in *"/tmp/leak-dir"*) FAIL=$((FAIL+1)); echo 'FAIL: show must not surface config.json BATON_DIR' >&2;; *) PASS=$((PASS+1));; esac

# Display-honesty: same for BATON_PROJECT_DIR (env-only consumer; config.json must not surface).
jq '.BATON_PROJECT_DIR="/tmp/leak-projdir"' "$XDG_CONFIG_HOME/baton/config.json" > "$TMP/c.json" && mv "$TMP/c.json" "$XDG_CONFIG_HOME/baton/config.json"
honp=$(unset BATON_PROJECT_DIR; bash "$DASH" show)
case "$honp" in *"/tmp/leak-projdir"*) FAIL=$((FAIL+1)); echo 'FAIL: show must not surface config.json BATON_PROJECT_DIR' >&2;; *) PASS=$((PASS+1));; esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
