#!/usr/bin/env bash
set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP"
export BATON_EVENT_LOG="$TMP/events.jsonl"
M='claude-opus-4-7'   # model id present in lib/cost-models.sh
passed=0; failed=0
assert_eq() { [[ "$1" == "$2" ]] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: $3 - expected [$2] got [$1]"; }; }
emit() { jq -cn --argjson sv 1 --arg ev cost_rollup --arg ts 2026-06-08T00:00:00Z --argjson d "$1" '{schema_version:$sv,event:$ev,ts:$ts,data:$d}' >> "$BATON_EVENT_LOG"; }
# arc-a: parent session s1 + sub-agent sub1 (distinct session_ids, same slug)
emit "$(jq -cn --arg m "$M" '{session_id:"s1",model:$m,cache_read:1000,cache_write_5m:200,cache_write_1h:0,fresh_input:500,output:300,project_slug:"arc-a",method:"none"}')"
# CC20: a crash/VM-pause zero-fill leaves a NUL run BETWEEN two valid arc-a records.
# A naive `jq -r ... "$log"` aborts here and silently drops every later event
# (undercounting arc-a). The tolerant reader (eventlog::stream) must skip it.
printf '\0\0\0\0\0\0\0\0\n' >> "$BATON_EVENT_LOG"
emit "$(jq -cn --arg m "$M" '{session_id:"sub1",model:$m,cache_read:0,cache_write_5m:0,cache_write_1h:0,fresh_input:100,output:50,project_slug:"arc-a",method:"none",transcript_basename:"subagent-x.jsonl"}')"
emit "$(jq -cn --arg m "$M" '{session_id:"s2",model:$m,cache_read:0,cache_write_5m:0,cache_write_1h:0,fresh_input:9999,output:9999,project_slug:"arc-b",method:"none"}')"
emit '{"session_id":"s3","model":"claude-opus-4-7","cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"fresh_input":7,"output":7}'
# arc-c: TWO models (opus + sonnet) with nonzero cache_write_5m/1h -> exercises the per-model accumulation loop AND cache_write summation
emit "$(jq -cn --arg m "$M" '{session_id:"c1",model:$m,cache_read:0,cache_write_5m:300,cache_write_1h:100,fresh_input:0,output:0,project_slug:"arc-c",method:"none"}')"
emit '{"session_id":"c2","model":"claude-sonnet-4-6","cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"fresh_input":400,"output":200,"project_slug":"arc-c","method":"none"}'
out="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-a --json)"
assert_eq "$(echo "$out" | jq -r .arc)" "arc-a" "reports arc slug"
assert_eq "$(echo "$out" | jq -r .events)" "2" "counts only this arc's events (parent+sub-agent, mixed session_id)"
assert_eq "$(echo "$out" | jq -r .tokens.fresh_input)" "600" "sums fresh_input incl sub-agent (500+100)"
assert_eq "$(echo "$out" | jq -r .tokens.output)" "350" "sums output incl sub-agent (300+50)"
assert_eq "$(echo "$out" | jq -r .tokens.cache_read)" "1000" "sums cache_read"
assert_eq "$(echo "$out" | jq -r '.usd > 0')" "true" "prices a positive USD total"
# human (non-json) path must print, NOT silently take the json branch
human="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-a)"
echo "$human" | grep -q 'usd: \$' && passed=$((passed+1)) || { failed=$((failed+1)); echo 'FAIL: human output missing usd line'; }
echo "$human" | grep -q 'fresh_input=600' && passed=$((passed+1)) || { failed=$((failed+1)); echo 'FAIL: human output missing token line'; }
# unknown arc -> zero events, exit 0
assert_eq "$(bash "$REPO_ROOT/tools/cost.sh" --arc nope --json | jq -r .events)" "0" "unknown arc -> events=0"
# arc-c: multi-model accumulation + nonzero cache_write summation
cout="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-c --json)"
assert_eq "$(echo "$cout" | jq -r .events)" "2" "arc-c counts both model events"
assert_eq "$(echo "$cout" | jq -r .tokens.cache_write_5m)" "300" "sums cache_write_5m (opus event)"
assert_eq "$(echo "$cout" | jq -r .tokens.cache_write_1h)" "100" "sums cache_write_1h (opus event)"
assert_eq "$(echo "$cout" | jq -r '.usd > 0')" "true" "multi-model arc (opus+sonnet) prices positive USD"
# arc-d: an UNPRICED/unknown model must be flagged, not silently $0 (the headline-cost honesty guarantee)
emit '{"session_id":"d1","model":"claude-future-9-9","cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"fresh_input":1000,"output":500,"project_slug":"arc-d","method":"none"}'
dout="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-d --json)"
assert_eq "$(echo "$dout" | jq -r .events)" "1" "arc-d counts the unpriced event"
assert_eq "$(echo "$dout" | jq -r .tokens.fresh_input)" "1000" "arc-d still sums tokens for an unpriced model"
assert_eq "$(echo "$dout" | jq -r '.unpriced_models | index("claude-future-9-9") != null')" "true" "arc-d flags the unpriced model id"
assert_eq "$(echo "$dout" | jq -r '.usd')" "0.000000" "arc-d unpriced model contributes 0 usd (but is flagged, not silently complete)"
# priced arcs report an empty unpriced_models list
assert_eq "$(echo "$cout" | jq -r '.unpriced_models | length')" "0" "fully-priced arc has empty unpriced_models"
# human path surfaces the unpriced warning
dhuman="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-d)"
echo "$dhuman" | grep -qi 'unpriced' && passed=$((passed+1)) || { failed=$((failed+1)); echo 'FAIL: human output missing unpriced warning'; }
# arc-e: a DATED id of a priced model (producer writes .message.model verbatim, e.g. claude-opus-4-7-20250101)
# must normalize to its alias and price > 0 - NOT be flagged unpriced (real-arc honest-total guarantee)
emit '{"session_id":"e1","model":"claude-opus-4-7-20250101","cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"fresh_input":1000,"output":500,"project_slug":"arc-e","method":"none"}'
eout="$(bash "$REPO_ROOT/tools/cost.sh" --arc arc-e --json)"
assert_eq "$(echo "$eout" | jq -r '.usd > 0')" "true" "arc-e dated-id of a priced model prices positive USD"
assert_eq "$(echo "$eout" | jq -r '.unpriced_models | length')" "0" "arc-e dated-id is normalized, not flagged unpriced"
# CC20: query.sh DuckDB must tolerate the same NUL line (ignore_errors=true) and
# NOT abort. DuckDB's ignore_errors emits an all-NULL phantom row for the NUL
# line rather than dropping it, so a bare count(*) over-counts by 1; count(event)
# (a column only real records carry) excludes the phantom and yields the true
# valid count. valid_n is derived from the log via the tolerant reader so this
# stays correct as fixtures evolve.
valid_n="$(jq -cR 'fromjson? // empty' "$BATON_EVENT_LOG" | grep -c .)"
qn="$(BATON_EVENT_LOG="$BATON_EVENT_LOG" bash "$REPO_ROOT/tools/query.sh" "SELECT count(event) AS n FROM events" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"
assert_eq "$qn" "$valid_n" "query.sh tolerates NUL line (no abort) + returns full valid count"
# durability: the query must EXIT SUCCESS (did not abort on the NUL line)
if BATON_EVENT_LOG="$BATON_EVENT_LOG" bash "$REPO_ROOT/tools/query.sh" "SELECT count(event) FROM events" >/dev/null 2>&1; then
  passed=$((passed+1))
else
  failed=$((failed+1)); echo 'FAIL: query.sh aborted (nonzero exit) on NUL-containing log'
fi
echo "Results: $passed passed, $failed failed"
exit $(( failed == 0 ? 0 : 1 ))
