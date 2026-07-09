#!/usr/bin/env bash
# lib/threshold-controller.sh - closed-loop checkpoint-threshold feedback controller (E-C).
#
# CAPABILITY ONLY. This builds the MECHANISM to adaptively change the checkpoint threshold:
# measure a score -> if it is off the setpoint by more than the deadband, step the threshold
# +/- one step (within a safety band) -> dwell -> (next run) re-measure. It does NOT decide the
# right setpoint/step/interval/equation: EVERY magnitude is a config knob with a placeholder
# default the owner replaces later from real data, and the scoring equation is a swappable named
# function (registry below). The decision function decide() therefore contains NO numeric literal.
#
# Scoring convention: a score ABOVE the setpoint means the threshold is too HIGH (step it down);
# BELOW means too LOW (step it up). A scoring function must orient its output to this convention.
# This keeps the control law polarity-free and fully config-driven.
#
# Numeric domains: the threshold and the step are INTEGER percentage points (the checkpoint
# threshold is bounds-validated to 1..99), so threshold/step arithmetic is integer bash $(( )).
# The setpoint, deadband, and score live in score-space and MAY be fractional - they are only
# ever compared (never used to step the threshold), and that comparison runs in awk, which is
# float-safe. Owner-set knobs follow these domains: integer tune_step, fractional setpoint/deadband ok.
set -uo pipefail
_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# config.sh: _cfg::get (read) + _cfg::set (write)
if ! declare -F _cfg::set >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_TC_DIR/config.sh" 2>/dev/null || true
fi
# workstream-lib.sh: checkpoint_threshold (the single, bounds-validated current-value authority)
if ! declare -F checkpoint_threshold >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_TC_DIR/../.claude/hooks/lib/workstream-lib.sh" 2>/dev/null || true
fi
# envelope.sh: envelope::emit + envelope::_active_arc (it self-locates its own config.sh)
if ! declare -F envelope::emit >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_TC_DIR/../.claude/hooks/lib/envelope.sh" 2>/dev/null || true
fi

# Knob readers - env BATON_TUNE_* > config.json tune_* > placeholder default (owner-set later).
threshold_controller::setpoint()      { _cfg::get BATON_TUNE_SETPOINT 0 tune_setpoint; }        # target score (placeholder)
threshold_controller::deadband()      { _cfg::get BATON_TUNE_DEADBAND 1 tune_deadband; }        # tolerance band around setpoint (placeholder)
threshold_controller::step()          { _cfg::get BATON_TUNE_STEP 2 tune_step; }                # threshold step size in pct points (placeholder)
threshold_controller::safety_min()    { _cfg::get BATON_TUNE_SAFETY_MIN 10 tune_safety_min; }   # lower safety bound (placeholder)
threshold_controller::safety_max()    { _cfg::get BATON_TUNE_SAFETY_MAX 50 tune_safety_max; }   # upper safety bound (placeholder)
threshold_controller::dwell_seconds() { _cfg::get BATON_TUNE_DWELL_SECONDS 86400 tune_dwell_seconds; }  # min seconds between applies (placeholder)
threshold_controller::score_fn()      { _cfg::get BATON_TUNE_SCORE_FN score_hold tune_score_fn; }       # selected scoring fn (placeholder; safe no-op default)

# Scoring registry. A score_* fn receives the current threshold ($1) and echoes a scalar score
# oriented so that score > setpoint => threshold too high. Swappable via tune_score_fn.
threshold_controller::score_hold()  { threshold_controller::setpoint; }   # default: == setpoint => HOLD (no-op until owner picks a real fn)
threshold_controller::score_above() { printf '%s' 999; }                  # demo/test: always above setpoint => step down
threshold_controller::score_below() { printf '%s' -999; }                 # demo/test: always below setpoint => step up

# Dispatch to the configured scoring fn; fall back to the safe no-op on an unknown name.
threshold_controller::score() {
  local current="$1" fn
  fn="$(threshold_controller::score_fn)"
  if declare -F "threshold_controller::${fn}" >/dev/null 2>&1; then
    "threshold_controller::${fn}" "$current"
  else
    printf 'threshold-controller: unknown score fn %q; using score_hold\n' "$fn" >&2
    threshold_controller::score_hold "$current"
  fi
}

# decide CURRENT SCORE -> echoes 'ACTION NEWVALUE' (ACTION in hold|up|down). Pure: reads knobs,
# compares score to setpoint vs deadband, steps the threshold by step. Contains NO numeric
# literal by construction (enforced by test-threshold-controller.sh).
threshold_controller::decide() {
  local current="$1" score="$2"
  local setpoint deadband step dir
  setpoint="$(threshold_controller::setpoint)"
  deadband="$(threshold_controller::deadband)"
  step="$(threshold_controller::step)"
  dir="$(awk -v s="$score" -v sp="$setpoint" -v db="$deadband" \
    'BEGIN{ e = s - sp; if (e > db) print "down"; else if (e < -db) print "up"; else print "hold" }')"
  case "$dir" in
    up)   printf 'up %s'   "$((current + step))" ;;
    down) printf 'down %s' "$((current - step))" ;;
    *)    printf 'hold %s' "$current" ;;
  esac
}

threshold_controller::_state_file() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/baton/threshold-tune-state.json"; }

# dwell_ok: true if no prior apply, or enough seconds have elapsed since the last one.
threshold_controller::dwell_ok() {
  local f dwell last now
  f="$(threshold_controller::_state_file)"
  dwell="$(threshold_controller::dwell_seconds)"
  [ -f "$f" ] || return 0
  last="$(jq -r '.last_apply_epoch // empty' "$f" 2>/dev/null)"
  [ -n "$last" ] || return 0
  now="$(date -u +%s)"
  [ "$(( now - last ))" -ge "$dwell" ]
}

threshold_controller::_record_apply() {
  local f now tmp; f="$(threshold_controller::_state_file)"; now="$(date -u +%s)"
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || printf '{}' > "$f"
  tmp=$(mktemp -p "$(dirname "$f")")
  jq --argjson t "$now" '.last_apply_epoch = $t' "$f" > "$tmp" && mv "$tmp" "$f"
}

threshold_controller::_emit_applied() {
  local old="$1" new="$2" action="$3" score="$4" data
  data="$(jq -cn --argjson o "$old" --argjson n "$new" --arg a "$action" --arg s "$score" \
    '{old_threshold:$o, new_threshold:$n, action:$a, score:$s}')"
  envelope::emit threshold_applied "$data"
}

# apply CURRENT PROPOSED ACTION SCORE - persist + emit ONLY when every guard passes.
threshold_controller::apply() {
  local current="$1" proposed="$2" action="$3" score="$4"
  # Echoes a status token (applied | suppressed:<reason> | held | failed) so callers can report
  # whether a write actually happened - a guard short-circuit is otherwise indistinguishable from
  # a successful apply. The threshold_applied event stays the authoritative apply record.
  # CC3: an explicit BATON_PCT_THRESHOLD env pin hard-overrides; never auto-apply over it.
  [ -n "${BATON_PCT_THRESHOLD:-}" ] && { printf 'suppressed:env-pin'; return 0; }
  # deadband: nothing to do on a hold decision.
  [ "$action" = hold ] && { printf 'held'; return 0; }
  # safety band: refuse a proposal that would leave [safety_min, safety_max].
  local lo hi; lo="$(threshold_controller::safety_min)"; hi="$(threshold_controller::safety_max)"
  { [ "$proposed" -lt "$lo" ] || [ "$proposed" -gt "$hi" ]; } && { printf 'suppressed:safety-band'; return 0; }
  # dwell: rate-limit applies.
  threshold_controller::dwell_ok || { printf 'suppressed:dwell'; return 0; }
  # persist via the single config write path, then make the apply observable.
  _cfg::set threshold_pct "$proposed" number || { printf 'failed'; return 1; }
  threshold_controller::_record_apply
  threshold_controller::_emit_applied "$current" "$proposed" "$action" "$score"
  printf 'applied'
}

# collection_on: events only land when an arc is open OR BATON_COLLECT=1 (envelope's gate).
threshold_controller::collection_on() {
  [ -n "$(envelope::_active_arc 2>/dev/null)" ] && return 0
  [ "$(_cfg::get BATON_COLLECT 0)" = 1 ]
}

# emit_snapshot: record the RESOLVED tuner knob vector for THIS session so the owner's
# data-exploration step can join a knob setting to its session's cost/outcome by session_id.
# Read-only (chooses NO numbers). The caller invokes this only from inside the collection-gated
# block, so a non-collecting session never reaches it; envelope::emit also self-gates on collection
# as defense-in-depth. The threshold is read AFTER any run_once apply, so it reflects this session's
# effective value. setpoint/deadband live in score-space (may be fractional) so they are recorded as
# strings, mirroring how _emit_applied records `score`; the integer-domain knobs are JSON numbers.
threshold_controller::emit_snapshot() {
  local sid="$1" data
  data="$(jq -cn \
    --arg     sid     "$sid" \
    --argjson thr     "$(checkpoint_threshold)" \
    --arg     set     "$(threshold_controller::setpoint)" \
    --arg     dead    "$(threshold_controller::deadband)" \
    --argjson step    "$(threshold_controller::step)" \
    --argjson smin    "$(threshold_controller::safety_min)" \
    --argjson smax    "$(threshold_controller::safety_max)" \
    --argjson dwell   "$(threshold_controller::dwell_seconds)" \
    --arg     fn      "$(threshold_controller::score_fn)" \
    --argjson collect "$(_cfg::get BATON_COLLECT 0)" \
    '{session_id:$sid, threshold:$thr, setpoint:$set, deadband:$dead, step:$step,
      safety_min:$smin, safety_max:$smax, dwell_seconds:$dwell, score_fn:$fn, collect:$collect}')"
  envelope::emit tuner_snapshot "$data"
}

# run_once: one control cycle - measure current threshold + score, decide, apply-if-allowed.
# Echoes 'ACTION CURRENT->PROPOSED (score=S) [STATUS]' where STATUS (from apply) reports whether
# the write landed (applied) or a guard blocked it (held | suppressed:<reason>). The leading
# ACTION field is preserved so `awk '{print $1}'` still yields hold|up|down.
threshold_controller::run_once() {
  local current score action proposed status
  current="$(checkpoint_threshold)"
  score="$(threshold_controller::score "$current")"
  read -r action proposed <<<"$(threshold_controller::decide "$current" "$score")"
  status="$(threshold_controller::apply "$current" "$proposed" "$action" "$score")"
  printf '%s %s->%s (score=%s) [%s]\n' "$action" "$current" "$proposed" "$score" "$status"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  threshold_controller::run_once
fi
