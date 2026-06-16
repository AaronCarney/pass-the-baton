#!/usr/bin/env bash
# test-recommend-integration.sh - integration smoke: wiring, flags, producer failures, boundary.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FX="$REPO/.claude/hooks/tests/fixtures/recommend"
PASS=0; FAIL=0

_pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# ── Setup ──
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Valid events log for reuse
EVENTS_VALID="$TMP/events-valid.jsonl"
cat > "$EVENTS_VALID" <<'EVENTS'
{"event":"project_boundary","ts":"2026-03-01T00:00:00Z","data":{"kind":"start","session_id":"int-1","terminal_id":"t1"}}
{"event":"project_boundary","ts":"2026-03-01T01:00:00Z","data":{"kind":"end","session_id":"int-1","terminal_id":"t1"}}
EVENTS

# ── (a) exit 0 on --help ──
bash "$REPO/tools/recommend.sh" --help >/dev/null 2>&1
[ $? -eq 0 ] && _pass "(a) --help exits 0" || _fail "(a) --help exits 0"

# ── (b) exit 0 on --json ──
bash "$REPO/tools/recommend.sh" \
  --log "$EVENTS_VALID" --corpus /nonexistent --json >/dev/null 2>&1
[ $? -eq 0 ] && _pass "(b) --json exits 0" || _fail "(b) --json exits 0"

# ── (c) exit 0 on --human ──
bash "$REPO/tools/recommend.sh" \
  --log "$EVENTS_VALID" --corpus /nonexistent --human >/dev/null 2>&1
[ $? -eq 0 ] && _pass "(c) --human exits 0" || _fail "(c) --human exits 0"

# ── (d) exit 1 on unknown flag ──
bash "$REPO/tools/recommend.sh" --bogus-flag >/dev/null 2>&1
[ $? -eq 1 ] && _pass "(d) --bogus-flag exits 1" || _fail "(d) --bogus-flag exits 1"

# ── (e) --log /no/such/path exits 0 (degrades gracefully) ──
bash "$REPO/tools/recommend.sh" \
  --log /no/such/path --corpus /nonexistent --json >/dev/null 2>&1
[ $? -eq 0 ] && _pass "(e) --log /no/such/path exits 0 (graceful)" \
  || _fail "(e) --log /no/such/path exits 0 (graceful)"

# ── (f) exit 0 on --corpus /no/such/dir ──
bash "$REPO/tools/recommend.sh" \
  --log "$EVENTS_VALID" --corpus /no/such/dir --json >/dev/null 2>&1
[ $? -eq 0 ] && _pass "(f) --corpus /no/such/dir exits 0" || _fail "(f) --corpus /no/such/dir exits 0"

# ── (g1) PRODUCER FAILURE - MALFORMED EVENTS branch ──
# events-producer-fail.jsonl is deliberately broken JSONL
MALFORMED="$FX/events-producer-fail.jsonl"
g1_json=$(bash "$REPO/tools/recommend.sh" \
  --log "$MALFORMED" \
  --corpus /nonexistent \
  --json 2>/dev/null)
g1_exit=$?
g1_cost=$(printf '%s' "$g1_json" | jq -r '.winners.cost | tostring' 2>/dev/null || echo "INVALID_JSON")
if [ "$g1_exit" -ne 0 ]; then
  _pass "(g1) malformed events → non-zero exit"
elif [ "$g1_cost" = "null" ]; then
  _pass "(g1) malformed events → graceful degradation (null winners, exit 0)"
else
  _fail "(g1) malformed events → expected non-zero or null winners (got cost=$g1_cost exit=$g1_exit)"
fi

# ── (g2) PRODUCER FAILURE - COST SWEEP RETURNS {} (empty corpus) ──
# Empty corpus dir → cost-sweep-corpus fails → cost.json = '{}' → cost_producer_degenerate=true
mkdir -p "$TMP/empty-corpus"
g2_json=$(bash "$REPO/tools/recommend.sh" \
  --log "$EVENTS_VALID" \
  --corpus "$TMP/empty-corpus" \
  --json 2>/dev/null)
g2_exit=$?
[ "$g2_exit" -eq 0 ] && _pass "(g2) empty corpus exits 0" || _fail "(g2) empty corpus exits 0 (got $g2_exit)"
g2_cost=$(printf '%s' "$g2_json" | jq -r '.winners.cost | tostring' 2>/dev/null)
[ "$g2_cost" = "null" ] && _pass "(g2) winners.cost==null" || _fail "(g2) winners.cost==null (got: $g2_cost)"
g2_degen=$(printf '%s' "$g2_json" | jq -r '.caveats.cost_producer_degenerate | tostring' 2>/dev/null)
[ "$g2_degen" = "true" ] && _pass "(g2) caveats.cost_producer_degenerate==true" \
  || _fail "(g2) caveats.cost_producer_degenerate==true (got: $g2_degen)"

# ── (h) REAL-CORPUS gate ──
if [ "${CC_E18_REAL_CORPUS:-}" = "1" ]; then
  real_exit_code=0
  bash "$REPO/tools/recommend.sh" --human >/dev/null 2>&1 || real_exit_code=$?
  [ "$real_exit_code" -eq 0 ] && _pass "(h) real-corpus exit 0" || _fail "(h) real-corpus exit 0 (got $real_exit_code)"
  real_cost=$(bash "$REPO/tools/recommend.sh" --json 2>/dev/null | jq -r '.winners.cost | tostring')
  [ "$real_cost" != "null" ] && _pass "(h) real-corpus winners.cost non-null" \
    || _fail "(h) real-corpus winners.cost non-null"
else
  printf 'SKIP: CC_E18_REAL_CORPUS=1 not set; real-corpus assertion not portable\n'
  _pass "(h) real-corpus gate: skipped (CC_E18_REAL_CORPUS not set)"
fi

# ── (i) --since override: .window.from=='2025-01-01' ──
since_json=$(bash "$REPO/tools/recommend.sh" \
  --log "$EVENTS_VALID" \
  --corpus /nonexistent \
  --since 2025-01-01 \
  --json 2>/dev/null)
win_from=$(printf '%s' "$since_json" | jq -r '.window.from // "null"')
[ "$win_from" = "2025-01-01" ] && _pass "(i) --since 2025-01-01 → window.from=='2025-01-01'" \
  || _fail "(i) --since 2025-01-01 → window.from=='2025-01-01' (got: $win_from)"

# ── (j) post_e16_days==30 BOUNDARY ──
# earliest outcome_proxy ts = 2026-04-29T00:00:00Z (exactly 30 days before CC_NOW=2026-05-29)
# → outcome_data_insufficient==false (closed-upper inclusive: 30 is sufficient)
cat > "$TMP/events-boundary30.jsonl" <<'EVENTS'
{"event":"project_boundary","ts":"2026-04-29T00:00:00Z","data":{"kind":"start","session_id":"b1","terminal_id":"t1"}}
{"event":"project_boundary","ts":"2026-04-29T01:00:00Z","data":{"kind":"end","session_id":"b1","terminal_id":"t1"}}
{"event":"outcome_proxy","ts":"2026-04-29T00:00:00Z","data":{"session_id":"b1","subkind":"code_execution","success":true}}
EVENTS
boundary_json=$(CC_NOW=2026-05-29 bash "$REPO/tools/recommend.sh" \
  --log "$TMP/events-boundary30.jsonl" \
  --corpus /nonexistent \
  --json 2>/dev/null)
# Use tostring to avoid jq's // treating false as falsy (jq: false // "null" returns "null")
boundary_insuff=$(printf '%s' "$boundary_json" | jq -r '.caveats.outcome_data_insufficient | tostring' 2>/dev/null)
[ "$boundary_insuff" = "false" ] && _pass "(j) post_e16_days==30 → outcome_data_insufficient==false" \
  || _fail "(j) post_e16_days==30 → outcome_data_insufficient==false (got: $boundary_insuff)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
