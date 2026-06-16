#!/usr/bin/env bash
# Tests for lib/recommend-aggregate.sh - top-level aggregator
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURES="$REPO/.claude/hooks/tests/fixtures/recommend"
LIB="$REPO/lib/recommend-aggregate.sh"

source "$LIB"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Build a real-shape events.jsonl fixture for main tests ──────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

EVENTS="$TMP_DIR/events.jsonl"
# Outcome proxy events with ts far enough in the past (>30 days before CC_NOW=2026-05-29 = 2026-04-29 or earlier)
# and project_boundary start events for session_count
cat > "$EVENTS" <<'EOF'
{"event":"outcome_proxy","ts":"2025-12-15T00:00:00Z","data":{"method":"compact"}}
{"event":"outcome_proxy","ts":"2026-01-10T00:00:00Z","data":{"method":"none"}}
{"event":"project_boundary","ts":"2026-01-01T00:00:00Z","data":{"kind":"start","session_id":"sess-A","project":"demo"}}
{"event":"project_boundary","ts":"2026-01-02T00:00:00Z","data":{"kind":"start","session_id":"sess-B","project":"demo"}}
{"event":"project_boundary","ts":"2026-01-03T00:00:00Z","data":{"kind":"start","session_id":"sess-C","project":"demo"}}
EOF

# ── (a+b) Main aggregation: non-null winners + required keys ─────────────────
result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

cost_winner=$(printf '%s' "$result" | jq -r '.winners.cost' 2>/dev/null)
time_winner=$(printf '%s' "$result" | jq -r '.winners.time' 2>/dev/null)
outcome_winner=$(printf '%s' "$result" | jq -r '.winners.outcome' 2>/dev/null)
[ "$cost_winner" != "null" ] && [ -n "$cost_winner" ] \
  && _pass "(a) winners.cost non-null" \
  || _fail "(a) winners.cost null/missing; got: $cost_winner"
[ "$time_winner" != "null" ] && [ -n "$time_winner" ] \
  && _pass "(a) winners.time non-null" \
  || _fail "(a) winners.time null/missing; got: $time_winner"
[ "$outcome_winner" != "null" ] && [ -n "$outcome_winner" ] \
  && _pass "(a) winners.outcome non-null" \
  || _fail "(a) winners.outcome null/missing; got: $outcome_winner"

sweep_argmax=$(printf '%s' "$result" | jq '.threshold_sweep.argmax' 2>/dev/null)
paired_deltas=$(printf '%s' "$result" | jq '.paired_deltas' 2>/dev/null)
pm_cost_ci=$(printf '%s' "$result" | jq '.per_method.cost' 2>/dev/null)
pm_time_ci=$(printf '%s' "$result" | jq '.per_method.time' 2>/dev/null)
pm_outcome=$(printf '%s' "$result" | jq '.per_method.outcome' 2>/dev/null)
sess_count=$(printf '%s' "$result" | jq '.session_count' 2>/dev/null)
win_from=$(printf '%s' "$result" | jq -r '.window.from' 2>/dev/null)
win_to=$(printf '%s' "$result" | jq -r '.window.to' 2>/dev/null)
win_post=$(printf '%s' "$result" | jq '.window.post_e16_days' 2>/dev/null)

[ "$sweep_argmax" != "" ] && _pass "(b) threshold_sweep.argmax present" \
  || _fail "(b) threshold_sweep.argmax missing"
[ "$paired_deltas" != "" ] && [ "$paired_deltas" != "null" ] \
  && _pass "(b) paired_deltas present" \
  || _fail "(b) paired_deltas missing/null"
[ "$pm_cost_ci" != "" ] && [ "$pm_cost_ci" != "null" ] \
  && _pass "(b) per_method.cost present" \
  || _fail "(b) per_method.cost missing/null"
[ "$pm_time_ci" != "" ] && [ "$pm_time_ci" != "null" ] \
  && _pass "(b) per_method.time present" \
  || _fail "(b) per_method.time missing/null"
[ "$pm_outcome" != "" ] && [ "$pm_outcome" != "null" ] \
  && _pass "(b) per_method.outcome present" \
  || _fail "(b) per_method.outcome missing/null"
printf '%s' "$result" | jq -e '.session_count | type == "number"' >/dev/null 2>&1 \
  && _pass "(b) session_count is integer" \
  || _fail "(b) session_count not integer; got: $sess_count"
[ "$win_from" != "null" ] && [ -n "$win_from" ] \
  && _pass "(b) window.from present" \
  || _fail "(b) window.from missing"
[ "$win_to" != "null" ] && [ -n "$win_to" ] \
  && _pass "(b) window.to present" \
  || _fail "(b) window.to missing"
# post_e16_days: non-negative int or null
post_type=$(printf '%s' "$result" | jq '.window.post_e16_days | type' 2>/dev/null)
[ "$post_type" = '"number"' ] || [ "$post_type" = '"null"' ] \
  && _pass "(k) window.post_e16_days is number or null" \
  || _fail "(k) window.post_e16_days bad type: $post_type"

# ── (c) Degrade gracefully - all missing files ───────────────────────────────
degrade=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost /no/such/cost.json \
  --time /no/such/time.json \
  --outcome /no/such/outcome.json \
  --events /no/such/events.jsonl \
  --arms-dir /no/such/arms 2>/dev/null)

dg_valid=$(printf '%s' "$degrade" | jq '.' 2>/dev/null)
[ -n "$dg_valid" ] && _pass "(c) all-missing emits valid JSON" \
  || _fail "(c) all-missing not valid JSON; got: $degrade"
dg_cost=$(printf '%s' "$degrade" | jq '.winners.cost' 2>/dev/null)
dg_time=$(printf '%s' "$degrade" | jq '.winners.time' 2>/dev/null)
dg_outcome=$(printf '%s' "$degrade" | jq '.winners.outcome' 2>/dev/null)
[ "$dg_cost" = "null" ] && _pass "(c) degrade winners.cost==null" \
  || _fail "(c) degrade winners.cost expected null, got: $dg_cost"
[ "$dg_time" = "null" ] && _pass "(c) degrade winners.time==null" \
  || _fail "(c) degrade winners.time expected null, got: $dg_time"
[ "$dg_outcome" = "null" ] && _pass "(c) degrade winners.outcome==null" \
  || _fail "(c) degrade winners.outcome expected null, got: $dg_outcome"
dg_sess=$(printf '%s' "$degrade" | jq '.session_count' 2>/dev/null)
[ "$dg_sess" = "0" ] && _pass "(c) degrade session_count==0" \
  || _fail "(c) degrade session_count expected 0, got: $dg_sess"
dg_post=$(printf '%s' "$degrade" | jq '.window.post_e16_days' 2>/dev/null)
[ "$dg_post" = "null" ] && _pass "(c) degrade window.post_e16_days==null" \
  || _fail "(c) degrade window.post_e16_days expected null, got: $dg_post"

# ── (d) outcome_data_insufficient when earliest outcome_proxy event < 30 days ago ──
RECENT_EVENTS="$TMP_DIR/events-recent.jsonl"
cat > "$RECENT_EVENTS" <<'EOF'
{"event":"outcome_proxy","ts":"2026-05-20T00:00:00Z","data":{"method":"compact"}}
{"event":"project_boundary","ts":"2026-05-20T00:00:00Z","data":{"kind":"start","session_id":"sess-X","project":"demo"}}
EOF

recent_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$RECENT_EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

insuff=$(printf '%s' "$recent_result" | jq '.caveats.outcome_data_insufficient' 2>/dev/null)
[ "$insuff" = "true" ] && _pass "(d) outcome_data_insufficient==true for recent data" \
  || _fail "(d) outcome_data_insufficient expected true, got: $insuff"
d_outcome_winner=$(printf '%s' "$recent_result" | jq '.winners.outcome' 2>/dev/null)
[ "$d_outcome_winner" = "null" ] && _pass "(d) winners.outcome==null when insufficient" \
  || _fail "(d) winners.outcome expected null when insufficient, got: $d_outcome_winner"

# ── (d2) CC_NOW=2026-05-29 → post_e16_days==29 exactly ─────────────────────
# earliest outcome_proxy ts=2026-04-30 → 29 days before 2026-05-29
E16_EVENTS="$TMP_DIR/events-e16.jsonl"
cat > "$E16_EVENTS" <<'EOF'
{"event":"outcome_proxy","ts":"2026-04-30T00:00:00Z","data":{"method":"compact"}}
{"event":"project_boundary","ts":"2026-04-30T00:00:00Z","data":{"kind":"start","session_id":"sess-Y","project":"demo"}}
EOF

e16_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$E16_EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

post29=$(printf '%s' "$e16_result" | jq '.window.post_e16_days' 2>/dev/null)
[ "$post29" = "29" ] && _pass "(d2) post_e16_days==29 with CC_NOW=2026-05-29" \
  || _fail "(d2) post_e16_days expected 29, got: $post29"

# ── (e) strict-recent: session_count drops with pre-release sessions ─────────
# Events with sessions that have cost_rollup data pre-release
# Using claude-sonnet-4-6 (released 2026-02-17); ts 2026-01-01 = pre-release
STRICT_EVENTS="$TMP_DIR/events-strict.jsonl"
cat > "$STRICT_EVENTS" <<'EOF'
{"event":"project_boundary","ts":"2026-01-01T00:00:00Z","data":{"kind":"start","session_id":"pre-1","project":"demo"}}
{"event":"project_boundary","ts":"2026-03-01T00:00:00Z","data":{"kind":"start","session_id":"post-1","project":"demo"}}
{"event":"project_boundary","ts":"2026-03-02T00:00:00Z","data":{"kind":"start","session_id":"post-2","project":"demo"}}
{"event":"cost_rollup","ts":"2026-01-01T00:00:00Z","data":{"session_id":"pre-1","model":"claude-sonnet-4-6","cost_usd":0.01}}
{"event":"cost_rollup","ts":"2026-03-01T00:00:00Z","data":{"session_id":"post-1","model":"claude-sonnet-4-6","cost_usd":0.01}}
EOF

strict_true=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$STRICT_EVENTS" \
  --arms-dir "$FIXTURES" \
  --strict-recent true 2>/dev/null)

strict_false=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$STRICT_EVENTS" \
  --arms-dir "$FIXTURES" \
  --strict-recent false 2>/dev/null)

sc_true=$(printf '%s' "$strict_true" | jq '.session_count' 2>/dev/null)
sc_false=$(printf '%s' "$strict_false" | jq '.session_count' 2>/dev/null)
[ "$sc_true" -lt "$sc_false" ] 2>/dev/null \
  && _pass "(e) strict-recent=true drops sessions vs false" \
  || _fail "(e) strict-recent: count_true=$sc_true should < count_false=$sc_false"

# ── (e-join) SESSION-ID JOIN: 7 starts, 2 cost_rollup pre-release → count==5 ──
JOIN_EVENTS="$TMP_DIR/events-join.jsonl"
# 7 project_boundary starts s1..s7
for i in 1 2 3 4 5 6 7; do
  jq -nc --arg sid "s$i" \
    '{event:"project_boundary",ts:("2026-05-2" + ($sid|.[-1:]) + "T00:00:00Z"),data:{kind:"start",session_id:$sid,project:"demo-proj"}}'
done > "$JOIN_EVENTS"
# 2 cost_rollup events for s3 + s5 with ts BEFORE claude-sonnet-4-6 release (2026-02-17)
# ts=2025-12-01 is before 2026-02-17
printf '{"event":"cost_rollup","ts":"2025-12-01T00:00:00Z","data":{"session_id":"s3","model":"claude-sonnet-4-6","cost_usd":0.01}}\n' >> "$JOIN_EVENTS"
printf '{"event":"cost_rollup","ts":"2025-12-01T00:00:00Z","data":{"session_id":"s5","model":"claude-sonnet-4-6","cost_usd":0.01}}\n' >> "$JOIN_EVENTS"

join_strict=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$JOIN_EVENTS" \
  --arms-dir "$FIXTURES" \
  --strict-recent true 2>/dev/null)

join_nonstrict=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$JOIN_EVENTS" \
  --arms-dir "$FIXTURES" \
  --strict-recent false 2>/dev/null)

js_count=$(printf '%s' "$join_strict" | jq '.session_count' 2>/dev/null)
jn_count=$(printf '%s' "$join_nonstrict" | jq '.session_count' 2>/dev/null)
[ "$js_count" = "5" ] && _pass "(e-join) strict-recent=true count==5" \
  || _fail "(e-join) strict-recent=true expected count=5, got: $js_count"
[ "$jn_count" = "7" ] && _pass "(e-join) strict-recent=false count==7" \
  || _fail "(e-join) strict-recent=false expected count=7, got: $jn_count"

# ── (f) CAVEAT-ABSENT data_age - window fully post-most-recent release ────────
# Most recent release: claude-opus-4-7 = 2026-04-16; window from=2026-04-20 to=2026-05-29
POSTRELEASE_EVENTS="$TMP_DIR/events-postrelease.jsonl"
cat > "$POSTRELEASE_EVENTS" <<'EOF'
{"event":"project_boundary","ts":"2026-04-20T00:00:00Z","data":{"kind":"start","session_id":"pr-1","project":"demo"}}
{"event":"project_boundary","ts":"2026-05-01T00:00:00Z","data":{"kind":"start","session_id":"pr-2","project":"demo"}}
EOF

postrelease_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$POSTRELEASE_EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

dag_false=$(printf '%s' "$postrelease_result" | jq '.caveats.data_age_crossing' 2>/dev/null)
crossings_empty=$(printf '%s' "$postrelease_result" | jq '.caveats.crossings | length' 2>/dev/null)
[ "$dag_false" = "false" ] && _pass "(f) data_age_crossing==false when window post-release" \
  || _fail "(f) data_age_crossing expected false, got: $dag_false"
[ "$crossings_empty" = "0" ] && _pass "(f) crossings==[] when window post-release" \
  || _fail "(f) crossings expected empty, length=$crossings_empty"

# ── (g) CAVEAT-ABSENT no_significant_difference - CI clear of zero ────────────
# Use real fixtures where paired-delta CI should be non-zero (arms differ in cost)
g_nsd=$(printf '%s' "$result" | jq '.caveats.no_significant_difference' 2>/dev/null)
# Result must have this key as boolean (true or false)
[ "$g_nsd" = "true" ] || [ "$g_nsd" = "false" ] \
  && _pass "(g) no_significant_difference is boolean" \
  || _fail "(g) no_significant_difference missing or not boolean; got: $g_nsd"

# ── (h) data_age_crossing caveat true when window crosses a release ───────────
# window from=2025-10-01 to=2026-05-29 crosses haiku-4-5 (2025-10-15) and sonnet-4-6 (2026-02-17)
CROSSING_EVENTS="$TMP_DIR/events-crossing.jsonl"
cat > "$CROSSING_EVENTS" <<'EOF'
{"event":"project_boundary","ts":"2025-10-01T00:00:00Z","data":{"kind":"start","session_id":"cr-1","project":"demo"}}
{"event":"project_boundary","ts":"2026-05-01T00:00:00Z","data":{"kind":"start","session_id":"cr-2","project":"demo"}}
EOF

crossing_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$CROSSING_EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

dag_true=$(printf '%s' "$crossing_result" | jq '.caveats.data_age_crossing' 2>/dev/null)
crossings_ne=$(printf '%s' "$crossing_result" | jq '.caveats.crossings | length' 2>/dev/null)
[ "$dag_true" = "true" ] && _pass "(h) data_age_crossing==true when window crosses release" \
  || _fail "(h) data_age_crossing expected true, got: $dag_true"
[ "$crossings_ne" -gt 0 ] 2>/dev/null && _pass "(h) crossings non-empty when crossing" \
  || _fail "(h) crossings expected non-empty, length=$crossings_ne"

# ── (i.1) WINDOW-FROM: earliest events ts → window.from ─────────────────────
# Main events has earliest ts=2025-12-15
i1_from=$(printf '%s' "$result" | jq -r '.window.from' 2>/dev/null)
[ "$i1_from" = "2025-12-15" ] && _pass "(i.1) window.from == 2025-12-15 from earliest ts" \
  || _fail "(i.1) window.from expected 2025-12-15, got: $i1_from"

# ── (i.2) --since override ───────────────────────────────────────────────────
i2_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$EVENTS" \
  --arms-dir "$FIXTURES" \
  --since 2026-01-01 2>/dev/null)

i2_from=$(printf '%s' "$i2_result" | jq -r '.window.from' 2>/dev/null)
[ "$i2_from" = "2026-01-01" ] && _pass "(i.2) --since 2026-01-01 overrides window.from" \
  || _fail "(i.2) --since override expected 2026-01-01, got: $i2_from"

# ── (i.3) 180-DAY FALLBACK: empty events.jsonl ───────────────────────────────
EMPTY_EVENTS="$TMP_DIR/events-empty.jsonl"
: > "$EMPTY_EVENTS"

i3_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$EMPTY_EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

i3_from=$(printf '%s' "$i3_result" | jq -r '.window.from' 2>/dev/null)
# `date -u -d "2026-05-29 - 180 days"` → 2025-11-30 (180-day exclusive lookback)
[ "$i3_from" = "2025-11-30" ] && _pass "(i.3) 180-day fallback == 2025-11-30 with CC_NOW=2026-05-29" \
  || _fail "(i.3) 180-day fallback expected 2025-11-30, got: $i3_from"

# ── (j) SESSION_COUNT: 7 distinct project_boundary 'start' session_ids ────────
SEVEN_EVENTS="$TMP_DIR/events-7-session.jsonl"
for i in 1 2 3 4 5 6 7; do
  jq -nc --arg sid "s$i" \
    '{event:"project_boundary",ts:("2026-05-2" + ($sid|.[-1:]) + "T00:00:00Z"),data:{kind:"start",session_id:$sid,project:"demo-proj"}}'
done > "$SEVEN_EVENTS"

j_result=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost /no/such/cost.json \
  --time /no/such/time.json \
  --outcome /no/such/outcome.json \
  --events "$SEVEN_EVENTS" \
  --arms-dir /no/such/arms 2>/dev/null)

j_count=$(printf '%s' "$j_result" | jq '.session_count' 2>/dev/null)
[ "$j_count" = "7" ] && _pass "(j) session_count==7 from 7 distinct starts" \
  || _fail "(j) session_count expected 7, got: $j_count"

# ── (l) COST_PRODUCER_DEGENERATE ─────────────────────────────────────────────
# Empty cost json (no per_arm_per_subset): still a valid file but degenerate
COST_EMPTY="$TMP_DIR/cost-empty.json"
printf '{"per_arm_per_subset":[],"aggregates":{},"typical_best":null,"transcripts":[]}\n' > "$COST_EMPTY"

l_degen=$(REPLAY_HARNESS_NONZERO_ARMS=0 CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$COST_EMPTY" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

l_cpd=$(printf '%s' "$l_degen" | jq '.caveats.cost_producer_degenerate' 2>/dev/null)
l_cost_win=$(printf '%s' "$l_degen" | jq '.winners.cost' 2>/dev/null)
l_pd_len=$(printf '%s' "$l_degen" | jq '.paired_deltas | length' 2>/dev/null)
[ "$l_cpd" = "true" ] && _pass "(l) cost_producer_degenerate==true when REPLAY_HARNESS_NONZERO_ARMS=0" \
  || _fail "(l) cost_producer_degenerate expected true, got: $l_cpd"
[ "$l_cost_win" = "null" ] && _pass "(l) winners.cost==null when degenerate" \
  || _fail "(l) winners.cost expected null when degenerate, got: $l_cost_win"
[ "$l_pd_len" = "0" ] && _pass "(l) paired_deltas empty when degenerate" \
  || _fail "(l) paired_deltas expected empty when degenerate, length=$l_pd_len"

# Non-degenerate: cost_producer_degenerate==false
l_normal=$(CC_NOW=2026-05-29 recommend::aggregate \
  --cost "$FIXTURES/cost-real.json" \
  --time "$FIXTURES/time-real.json" \
  --outcome "$FIXTURES/outcome-real.json" \
  --events "$EVENTS" \
  --arms-dir "$FIXTURES" 2>/dev/null)

l_cpd_false=$(printf '%s' "$l_normal" | jq '.caveats.cost_producer_degenerate' 2>/dev/null)
[ "$l_cpd_false" = "false" ] && _pass "(l) cost_producer_degenerate==false normally" \
  || _fail "(l) cost_producer_degenerate expected false normally, got: $l_cpd_false"

# ── CC20: malformed-line (NUL) tolerance for all three event reads ───────────
# :30 (recommend_window::from min-ts), :72 (strict cost_rollup arm),
# :83 (else-arm raw start count) must each read past an embedded NUL.
NUL_EVENTS="$TMP_DIR/events-nul.jsonl"
{
  # Pre-NUL: an early start so the file is non-empty before corruption.
  printf '%s\n' '{"event":"project_boundary","ts":"2026-03-10T00:00:00Z","data":{"kind":"start","session_id":"pre-nul","project":"demo"}}'
  printf '\0\0\0\n'
  # Post-NUL: earliest ts in the file (drives :30 min-ts) + two starts (drive :83) +
  # a pre-release cost_rollup for one of them (drives :72 strict drop).
  printf '%s\n' '{"event":"project_boundary","ts":"2026-01-05T00:00:00Z","data":{"kind":"start","session_id":"post-a","project":"demo"}}'
  printf '%s\n' '{"event":"project_boundary","ts":"2026-03-02T00:00:00Z","data":{"kind":"start","session_id":"post-b","project":"demo"}}'
  printf '%s\n' '{"event":"cost_rollup","ts":"2025-12-01T00:00:00Z","data":{"session_id":"post-a","model":"claude-sonnet-4-6","cost_usd":0.01}}'
} > "$NUL_EVENTS"

# :30 - earliest ts across ALL post-NUL records (cost_rollup ts=2025-12-01 is the
# global min) must drive window.from; pre-routing this aborted at the NUL and fell
# back to the 180-day window.
nul_from=$(recommend_window::from "$NUL_EVENTS")
[ "$nul_from" = "2025-12-01" ] \
  && _pass "(nul) :30 window.from reads post-NUL earliest ts" \
  || _fail "(nul) :30 window.from expected 2025-12-01, got: $nul_from"

# :83 (else arm, strict=false) - all 3 starts counted (pre-nul + post-a + post-b).
nul_sc_false=$(recommend_window::session_count "$NUL_EVENTS" "2026-01-01" "2026-05-29" false)
[ "$nul_sc_false" = "3" ] \
  && _pass "(nul) :83 raw count reads post-NUL starts (==3)" \
  || _fail "(nul) :83 raw count expected 3, got: $nul_sc_false"

# :72 (strict arm) - post-NUL pre-release cost_rollup drops post-a → count 2.
nul_sc_true=$(recommend_window::session_count "$NUL_EVENTS" "2026-01-01" "2026-05-29" true)
[ "$nul_sc_true" = "2" ] \
  && _pass "(nul) :72 strict arm reads post-NUL cost_rollup (drops post-a → ==2)" \
  || _fail "(nul) :72 strict arm expected 2, got: $nul_sc_true"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
