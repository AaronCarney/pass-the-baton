#!/usr/bin/env bash
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"
PASS=0; FAIL=0
assert(){ if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
mkp(){ local d; d=$(mktemp -d); mkdir -p "$d/docs/sessions/.tracking/"{terminals,workstreams} "$d/projects"; echo "$d"; }
seed_full(){ # ws 'shared' already has one fresh OTHER terminal
  local tr="$1"; jq -n '{workstream:"shared",display_name:"shared",progress_file:"/p.md",phase:"implementation",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",session_id:"owner-sid"}' > "$tr/workstreams/shared.json"
  local oth; oth=$(USER=u CLAUDE_TERMINAL_ID=OTH term_hash)
  jq -n '{terminal_id:"OTH",workstream:"shared",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tr/terminals/${oth}.json"; }

# A: explicit WORKSTREAM= over cap -> warns + binds
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
out=$(WORKSTREAM=shared BATON_MAX_TERMINALS_PER_WORKSTREAM=1 USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' 2>&1)
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
assert "A-binds-anyway" "[ \"\$(jq -r .workstream \"$tr/terminals/${me}.json\")\" = shared ]"
assert "A-warns" "echo \"\$out\" | grep -qi 'max'"
assert "A-snapshot-note" "echo \"\$out\" | grep -qi 'other terminal'"
rm -rf "$proj"
# B: session_id-return over cap -> exempt (no warning). Seed 'shared' with THIS session's id, no terminal binding for ME.
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
jq '.session_id="me-sid"' "$tr/workstreams/shared.json" > "$tr/workstreams/shared.tmp" && mv "$tr/workstreams/shared.tmp" "$tr/workstreams/shared.json"
out=$(BATON_MAX_TERMINALS_PER_WORKSTREAM=1 USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' 2>&1)
assert "B-reacquires" "[ \"\$(jq -r .workstream \"$tr/terminals/$(USER=u CLAUDE_TERMINAL_ID=ME term_hash).json\")\" = shared ]"
assert "B-no-warn" "! echo \"\$out\" | grep -qi 'max of'"
rm -rf "$proj"
# C: subagent over cap -> exempt (AGENT_SESSION_ID set, read-only)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
jq -n '{terminal_id:"ME",workstream:"shared",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tr/terminals/${me}.json"
set +e; out=$(AGENT_SESSION_ID=ag BATON_MAX_TERMINALS_PER_WORKSTREAM=1 USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"ag","cwd":"'"$proj"'"}' 2>&1); rc=$?; set -e 2>/dev/null || true
assert "C-subagent-not-blocked" "[ $rc -eq 0 ]"
rm -rf "$proj"
# D: grandfather - ME already on shared, cap lowered below occupancy, session_id-return keeps ME on shared (never evict)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
jq '.session_id="me-sid"' "$tr/workstreams/shared.json" > "$tr/workstreams/shared.tmp" && mv "$tr/workstreams/shared.tmp" "$tr/workstreams/shared.json"
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
jq -n '{terminal_id:"ME",workstream:"shared",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tr/terminals/${me}.json"
BATON_MAX_TERMINALS_PER_WORKSTREAM=1 USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' >/dev/null 2>&1
assert "D-grandfather-keeps-ws" "[ \"\$(jq -r .workstream \"$tr/terminals/${me}.json\")\" = shared ]"
rm -rf "$proj"
# E: solo main session, no co-tenant -> NO snapshot NOTE (silent below the >1 threshold)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"
out=$(WORKSTREAM=solo USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"solo-sid","cwd":"'"$proj"'"}' 2>&1)
assert "E-solo-no-note" "! echo \"\$out\" | grep -qi 'other terminal'"
rm -rf "$proj"
# F: .closed_at cleared when the terminal re-binds (session_id-return re-activates ME)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
jq '.session_id="me-sid"' "$tr/workstreams/shared.json" > "$tr/workstreams/shared.tmp" && mv "$tr/workstreams/shared.tmp" "$tr/workstreams/shared.json"
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
jq -n '{terminal_id:"ME",workstream:"shared",updated_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",closed_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$tr/terminals/${me}.json"
USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' >/dev/null 2>&1
assert "F-closed-at-cleared" "[ -z \"\$(jq -r '.closed_at // empty' \"$tr/terminals/${me}.json\")\" ]"
rm -rf "$proj"
# G: malformed cap env -> degrades to unlimited (binds, no 'max' warning, no integer-expr stderr leak)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed_full "$tr"
out=$(WORKSTREAM=shared BATON_MAX_TERMINALS_PER_WORKSTREAM=abc USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' 2>&1)
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
assert "G-binds-anyway" "[ \"\$(jq -r .workstream \"$tr/terminals/${me}.json\")\" = shared ]"
assert "G-no-cap-warn" "! echo \"\$out\" | grep -qi 'max of'"
assert "G-no-integer-error" "! echo \"\$out\" | grep -qi 'integer expression'"
rm -rf "$proj"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
