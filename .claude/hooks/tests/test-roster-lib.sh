#!/usr/bin/env bash
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
mkt(){ local d; d=$(mktemp -d); mkdir -p "$d/terminals" "$d/workstreams"; echo "$d"; }
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

T=$(mkt)
# two FRESH terminals on ws-A, one STALE (old updated_at), one CLOSED (has .closed_at)
jq -n --arg ws ws-A --arg u "$(now)" '{terminal_id:"t1",workstream:$ws,updated_at:$u}' > "$T/terminals/h1.json"
jq -n --arg ws ws-A --arg u "$(now)" '{terminal_id:"t2",workstream:$ws,updated_at:$u}' > "$T/terminals/h2.json"
jq -n --arg ws ws-A '{terminal_id:"t3",workstream:$ws,updated_at:"2020-01-01T00:00:00Z"}' > "$T/terminals/h3.json"
jq -n --arg ws ws-A --arg u "$(now)" '{terminal_id:"t4",workstream:$ws,updated_at:$u,closed_at:$u}' > "$T/terminals/h4.json"

assert "count-excludes-stale-and-closed" "[ \"\$(workstream_terminal_count \"$T\" ws-A)\" = 2 ]"
assert "count-excludes-self" "[ \"\$(workstream_terminal_count \"$T\" ws-A h1)\" = 1 ]"
assert "roster-lists-fresh-hashes" "workstream_roster \"$T\" ws-A | grep -qx h2"
assert "roster-omits-closed" "! workstream_roster \"$T\" ws-A | grep -qx h4"

# freshness predicate on a ws record
jq -n '{workstream:"w",display_name:"w",progress_file:"",phase:"unknown",updated_at:"x"}' > "$T/workstreams/fresh.json"
jq -n '{workstream:"w",display_name:"w",progress_file:"/p.md",phase:"implementation",updated_at:"x"}' > "$T/workstreams/established.json"
assert "is-fresh-true" "workstream_is_fresh \"$T/workstreams/fresh.json\""
assert "is-fresh-false" "! workstream_is_fresh \"$T/workstreams/established.json\""

rm -rf "$T"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
