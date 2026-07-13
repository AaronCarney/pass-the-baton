#!/bin/bash
# Integration tests for workstream hooks (session-start, checkpoint-write-trigger).
# Runs each scenario in an isolated tmp CLAUDE_PROJECT_DIR, asserts outcomes, tallies results.
# Usage: bash .claude/hooks/tests/test-workstream-hooks.sh
#
# v2 port manifest (per the internal design notes):
# DELETE: T1, T2, T3, T4, T5, T6, T7, T8, T10, T11, T12, T13, T17, T18  (14 v1-specific)
# ADAPT:  T9 -> run_t9_v2, T14 -> run_t14_v2, T15 -> run_t15_v2,
#         T19 -> run_t19_v2, T21 -> run_t21_v2_fallback
# KEEP:   T20  (log_event semantics unchanged)

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
CP="$HOOKS_DIR/checkpoint-write-trigger.sh"
CC="$HOOKS_DIR/context-checkpoint.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    echo "  PASS  $name"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$name")
    echo "  FAIL  $name"
  fi
}

mkproj() {
  # Callers invoke as `proj=$(mkproj)`; the `export` lines below were
  # subshell-only no-ops (OD-subshell-export, removed in E5a-T7). Callers
  # set BATON_DIR/BATON_PROGRESS_DIR inline on every bash invocation.
  local d
  d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking" "$d/projects"
  # Stub template so the write-trigger's V1 lint compares empty-vs-empty.
  # These scenarios test workstream save logic, not template enforcement.
  mkdir -p "$d/share/templates" && : > "$d/share/templates/free.md"
  echo "$d"
}

mkproject_link() {
  local root="$1" name="$2"
  mkdir -p "$root/proj-${name}"
  ln -s "$root/proj-${name}" "$root/projects/${name}"
  readlink -f "$root/projects/${name}"
}

seed_pointer() {
  local tracking="$1" ws="$2" lp="$3" dn="$4" tid="${5:-}" age_hours="${6:-0}"
  local f="$tracking/active-${ws}.json"
  jq -n --arg ws "$ws" --arg lp "$lp" --arg dn "$dn" --arg tid "$tid" \
    '{workstream:$ws, latest_progress:$lp, display_name:$dn, terminal_id:$tid, phase:"unknown"}' \
    > "$f"
  [ "$age_hours" -gt 0 ] && touch -d "${age_hours} hours ago" "$f"
}

run_session_start() {
  local proj="$1" term="$2" sid="${3:-sess-$(date +%s%N)}" ws_env="${4:-}"
  WORKSTREAM="$ws_env" CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="${BATON_DIR:-$proj/docs/sessions/.tracking}" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}"
  echo "$sid"  # last-line sentinel for callers
}

# ----- session-start tests -----

echo "## session-start.sh"

# T9_v2: fresh workstream writes display_name into workstreams/<ws>.json
run_t9_v2() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  mkproject_link "$proj" "gamma" >/dev/null
  local real_gamma; real_gamma=$(readlink -f "$proj/projects/gamma")
  local sid="sid-t9v2-$$"
  BATON_DISPLAY_NAME=gamma USER=u CLAUDE_TERMINAL_ID=G CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$real_gamma\"}" >/dev/null
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=G term_hash)
  local term_file="$proj/docs/sessions/.tracking/terminals/${th}.json"
  assert "T9v2: terminals/<hash>.json created" "[ -f '$term_file' ]"
  local ws; ws=$(jq -r .workstream "$term_file" 2>/dev/null)
  local ws_file="$proj/docs/sessions/.tracking/workstreams/${ws}.json"
  assert "T9v2: workstreams/<ws>.json created" "[ -f '$ws_file' ]"
  local dn; dn=$(jq -r '.display_name // ""' "$ws_file" 2>/dev/null)
  assert "T9v2: workstreams/<ws>.display_name = gamma" "[ '$dn' = 'gamma' ]"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_t9_v2

# ----- checkpoint-write-trigger tests -----

echo "## checkpoint-write-trigger.sh"

run_checkpoint() {
  local proj="$1" sid="$2" cwd="$3" file="$4" term="${5:-CTerm}"
  echo "{\"session_id\":\"$sid\",\"cwd\":\"$cwd\",\"tool_input\":{\"file_path\":\"$file\"}}" | \
    USER=u CLAUDE_TERMINAL_ID="$term" CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/docs/sessions/.tracking" bash "$CP"
}

# seed_terminal: write terminals/<hash>.json + workstreams/<ws>.json for v2 checkpoint tests.
# Usage: seed_terminal "$tracking" "$term_id" "$ws" "$display"
seed_terminal() {
  local tracking="$1" term_id="$2" ws="$3" display="${4:-}"
  mkdir -p "$tracking/workstreams" "$tracking/terminals"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID="$term_id" term_hash)
  jq -n --arg tid "$term_id" --arg ws "$ws" \
    '{terminal_id:$tid, workstream:$ws, updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # Create workstreams record if not already present
  local wsf="$tracking/workstreams/${ws}.json"
  if [ ! -f "$wsf" ]; then
    jq -n --arg ws "$ws" --arg dn "$display" \
      '{workstream:$ws, display_name:$dn, progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
      > "$wsf"
  fi
}

# T14_v2: same-project normal checkpoint -> workstreams/<ws>.json updated with progress_file + updated_at
run_t14_v2() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-t14v2-$$"
  local t_file="$proj/docs/sessions/.tracking/ok-t.json"
  echo '{"workstream":"alpha-ws","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  seed_terminal "$proj/docs/sessions/.tracking" "CTerm" "alpha-ws" "alpha"
  local before_ts; before_ts=$(jq -r '.updated_at' "$proj/docs/sessions/.tracking/workstreams/alpha-ws.json")
  touch "/tmp/baton-pending-$sid"
  local f="$proj/docs/sessions/progress-alpha-ws-ok.md"
  echo "# ok" > "$f"
  local out; out=$(run_checkpoint "$proj" "$sid" "$alpha" "$f")
  assert "T14v2: no warning for same-project" "! echo \"\$out\" | grep -q 'WARNING'"
  local ws_file="$proj/docs/sessions/.tracking/workstreams/alpha-ws.json"
  local ap_pf; ap_pf=$(jq -r '.progress_file' "$ws_file")
  assert "T14v2: workstreams/<ws>.progress_file updated" "[ '$ap_pf' = '$f' ]"
  local after_ts; after_ts=$(jq -r '.updated_at' "$ws_file")
  assert "T14v2: workstreams/<ws>.updated_at bumped" "[ '$after_ts' != '$before_ts' ]"
  assert "T14v2: save event logged" "jq -e 'select(.event==\"save\")' '$proj/docs/sessions/.tracking/hook-events.jsonl' >/dev/null 2>&1"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj"
}
run_t14_v2

# T15_v2: checkpoint creates workstreams/<ws>.json on first write (no terminal_id field check - moved to terminals/<hash>.json)
run_t15_v2() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-t15v2-$$"
  local t_file="$proj/docs/sessions/.tracking/new-t.json"
  echo '{"workstream":"fresh-ws","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  # Bind terminal to fresh-ws but force workstreams/fresh-ws.json absent to test creation path
  seed_terminal "$proj/docs/sessions/.tracking" "CTerm" "fresh-ws" "alpha"
  rm -f "$proj/docs/sessions/.tracking/workstreams/fresh-ws.json"
  touch "/tmp/baton-pending-$sid"
  local f="$proj/docs/sessions/progress-fresh-ws-x.md"
  echo "# fresh" > "$f"
  run_checkpoint "$proj" "$sid" "$alpha" "$f" >/dev/null
  local ws_file="$proj/docs/sessions/.tracking/workstreams/fresh-ws.json"
  assert "T15v2: workstreams/<ws>.json created" "[ -f '$ws_file' ]"
  assert "T15v2: progress_file populated" "[ \"\$(jq -r .progress_file '$ws_file')\" = '$f' ]"
  assert "T15v2: updated_at populated" "[ -n \"\$(jq -r '.updated_at // \"\"' '$ws_file')\" ]"
  # In v2, terminal_id is NOT a field on workstreams/<ws>.json - it lives on terminals/<hash>.json
  assert "T15v2: workstreams/<ws>.json has no terminal_id field" \
    "[ \"\$(jq 'has(\"terminal_id\")' '$ws_file')\" = 'false' ]"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj"
}
run_t15_v2

# T19_v2: end-to-end - after checkpoint, same terminal recovers progress via terminals/<hash>.json
# (No 24h time-gate - recovery works whenever workstreams/<ws>.json is within 48h prune window.)
run_t19_v2() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-t19v2-$$"
  local t_file="$proj/docs/sessions/.tracking/e2e-t.json"
  echo '{"workstream":"ws-e2e","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  seed_terminal "$proj/docs/sessions/.tracking" "StickyTerm" "ws-e2e" "alpha"
  touch "/tmp/baton-pending-$sid"
  local f="$proj/docs/sessions/progress-ws-e2e-x.md"
  echo "# saved" > "$f"
  # Checkpoint writes workstreams/ws-e2e.json with progress_file
  run_checkpoint "$proj" "$sid" "$alpha" "$f" StickyTerm >/dev/null
  # New session same terminal - should recover via terminals/<hash>.json -> workstreams/ws-e2e.json
  local sid2="sid-t19v2-next-$$"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=StickyTerm CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    bash "$SS" <<<"{\"session_id\":\"$sid2\",\"cwd\":\"$alpha\"}")
  assert "T19v2: end-to-end post-checkpoint recovery via terminals/<hash>.json" \
    "echo \"\$out\" | grep -q '# saved'"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid" \
        "/tmp/claude-session-tracking-$sid2"
  rm -rf "$proj"
}
run_t19_v2

# T21_v2_fallback: term_hash produces a non-empty 32-char hash via tty/ppid fallback when CLAUDE_TERMINAL_ID is unset.
run_t21_v2_fallback() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local h
  h=$(env -u CLAUDE_TERMINAL_ID USER=testuser bash -c \
    'source "'$HOOKS_DIR'/lib/workstream-lib.sh"; term_hash' 2>/dev/null)
  assert "T21v2: term_hash returns non-empty hash via fallback" "[ -n '$h' ]"
  assert "T21v2: fallback hash is 32 chars (md5)" "[ ${#h} -eq 32 ]"
  # term_hash_source returns the raw resolved source value (tty path or ppid-tty) - non-empty means a fallback tier resolved.
  local src
  src=$(env -u CLAUDE_TERMINAL_ID USER=testuser bash -c \
    'source "'$HOOKS_DIR'/lib/workstream-lib.sh"; term_hash_source' 2>/dev/null)
  assert "T21v2: term_hash_source non-empty (fallback tier resolved)" "[ -n '$src' ]"
  # Fallback source must NOT be CLAUDE_TERMINAL_ID since we unset it
  assert "T21v2: term_hash_source not from CLAUDE_TERMINAL_ID" "[ '$src' != \"\${CLAUDE_TERMINAL_ID:-}\" ]"
}
run_t21_v2_fallback

# T20: log_event records session_id in events (driven via checkpoint hook - only caller of log_event in v2)
run_t20() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-t20-abc"
  local t_file="$proj/docs/sessions/.tracking/t20-t.json"
  echo '{"workstream":"alpha-ws","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  seed_terminal "$proj/docs/sessions/.tracking" "CTerm" "alpha-ws" "alpha"
  touch "/tmp/baton-pending-$sid"
  local f="$proj/docs/sessions/progress-alpha-ws-t20.md"
  echo "# t20" > "$f"
  run_checkpoint "$proj" "$sid" "$alpha" "$f" >/dev/null
  local log="$proj/docs/sessions/.tracking/hook-events.jsonl"
  local logged; logged=$(jq -r 'select(.session_id=="'"$sid"'") | .session_id' "$log" 2>/dev/null | head -1)
  assert "T20: log_event records session_id" "[ '$logged' = '$sid' ]"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj"
}
run_t20

# T16: basename mismatch → hook warns and skips cleanup (pre-existing guard)
run_t16() {
  local proj; proj=$(mkproj)
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-t16-$$"
  local t_file="$proj/docs/sessions/.tracking/bn-t.json"
  echo '{"workstream":"alpha-ws","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  touch "/tmp/baton-pending-$sid"
  # Progress filename doesn't reference the workstream
  local f="$proj/docs/sessions/progress-wrong-name.md"
  echo "# unrelated" > "$f"
  local out; out=$(run_checkpoint "$proj" "$sid" "$alpha" "$f")
  assert "T16: basename mismatch warns" "echo \"\$out\" | grep -q 'does not contain current workstream'"
  assert "T16: file left in place" "[ -f '$f' ]"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj"
}
run_t16

# ----- term_hash fallback tests -----

echo "## term_hash fallback chain"

run_th_1() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local h
  h=$(USER=testuser CLAUDE_TERMINAL_ID=ABC123 term_hash)
  local expected
  expected=$(echo -n "testuser:ABC123" | md5sum | cut -d' ' -f1)
  assert "TH1: TID set → md5(USER:CLAUDE_TERMINAL_ID)" "[ '$h' = '$expected' ]"
}
run_th_1

run_th_2() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  # Force tty fallback by unsetting CLAUDE_TERMINAL_ID
  local h
  h=$(USER=testuser CLAUDE_TERMINAL_ID="" term_hash 2>/dev/null)
  assert "TH2: TID empty → falls back to tty or ppid (non-empty hash)" "[ -n '$h' ] && [ ${#h} -eq 32 ]"
}
run_th_2

run_th_3() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  # All sources fail: TID empty, tty redirected (subshell with </dev/null)
  local h
  h=$(USER=testuser CLAUDE_TERMINAL_ID="" bash -c 'source "'$HOOKS_DIR'/lib/workstream-lib.sh"; term_hash' </dev/null 2>/dev/null)
  assert "TH3: all sources fail → ppid fallback still produces hash" "[ -n '$h' ] && [ ${#h} -eq 32 ]"
}
run_th_3

run_lib_clean_1() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  assert "LIB1: _sticky_hash deleted" "! declare -f _sticky_hash >/dev/null"
  assert "LIB2: sticky_path deleted" "! declare -f sticky_path >/dev/null"
  assert "LIB3: read_sticky deleted" "! declare -f read_sticky >/dev/null"
  assert "LIB4: write_sticky deleted" "! declare -f write_sticky >/dev/null"
  assert "LIB5: _legacy_sticky_path deleted" "! declare -f _legacy_sticky_path >/dev/null"
}
run_lib_clean_1

# run_prune_1 removed - prune_stale_workstreams deleted in T2 (cron-only mutation, CC4).
# Cron-side prune coverage lives in cron tests added in later tasks of this epoch.

# ----- v2 routing rule tests -----

echo "## v2 routing rule"

mkv2() {
  # Subshell-only exports removed in E5a-T7 (OD-subshell-export).
  local d
  d=$(mktemp -d)
  mkdir -p "$d/docs/sessions/.tracking/workstreams" "$d/docs/sessions/.tracking/terminals" "$d/projects"
  # Stub template so the write-trigger's V1 lint compares empty-vs-empty.
  mkdir -p "$d/share/templates" && : > "$d/share/templates/free.md"
  echo "$d"
}

run_v2_happy() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  echo "# progress" > "$proj/docs/sessions/progress-w1.md"
  jq -n '{workstream:"w1", display_name:"W1", progress_file:"docs/sessions/progress-w1.md", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/w1.json"
  # Compute term_hash for our test terminal_id
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TX term_hash)
  jq -n '{terminal_id:"TX", workstream:"w1", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TX CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-v2h\",\"cwd\":\"$proj\"}")
  assert "V2-HAPPY: progress injected" "echo \"\$out\" | grep -q '# progress'"
  rm -rf "$proj"
}
run_v2_happy

run_v2_fresh() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TY term_hash)
  USER=u CLAUDE_TERMINAL_ID=TY CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-fresh\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-FRESH: terminals/<hash>.json created" "[ -f '$tracking/terminals/${th}.json' ]"
  local ws
  ws=$(jq -r .workstream "$tracking/terminals/${th}.json")
  assert "V2-FRESH: terminal binds to fresh workstream" "[ -n \"\$ws\" ]"
  assert "V2-FRESH: workstreams/<ws>.json created" "[ -f \"\$(ls $tracking/workstreams/*.json | head -1)\" ]"
  rm -rf "$proj"
}
run_v2_fresh

run_v2_ws_missing() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TZ term_hash)
  # Terminal state pointing at a workstream file that doesn't exist
  jq -n '{terminal_id:"TZ", workstream:"gone", updated_at:"2026-05-01T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TZ CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-wsm\",\"cwd\":\"$proj\"}")
  assert "V2-WS-MISSING: user-visible note printed" "echo \"\$out\" | grep -qi 'previous workstream unavailable'"
  assert "V2-WS-MISSING: fresh workstream created" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" != 'gone' ]"
  rm -rf "$proj"
}
run_v2_ws_missing

run_v2_ws_corrupt() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TC term_hash)
  jq -n '{terminal_id:"TC", workstream:"corrupt", updated_at:"2026-05-01T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  echo "{not-valid-json" > "$tracking/workstreams/corrupt.json"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TC CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-cor\",\"cwd\":\"$proj\"}")
  assert "V2-WS-CORRUPT: treated as missing → note + fresh-creation" \
    "echo \"\$out\" | grep -qi 'previous workstream unavailable'"
  rm -rf "$proj"
}
run_v2_ws_corrupt

run_v2_progress_empty() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TE term_hash)
  jq -n '{workstream:"e", display_name:"E", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/e.json"
  jq -n '{terminal_id:"TE", workstream:"e", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # E5a-T2: simulate cron has run so the cron-probe stays quiet
  # (test's intent is empty-progress quiet path, not cron concern)
  touch "$tracking/.cron-last-run"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TE CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-empty\",\"cwd\":\"$proj\"}")
  assert "V2-PROG-EMPTY: no Workstream Progress block" "! echo \"\$out\" | grep -q 'Workstream Progress'"
  assert "V2-PROG-EMPTY: no WARNING" "! echo \"\$out\" | grep -q 'WARNING'"
  rm -rf "$proj"
}
run_v2_progress_empty

run_v2_progress_missing() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TM term_hash)
  jq -n '{workstream:"m", display_name:"M", progress_file:"docs/sessions/progress-gone.md", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/m.json"
  jq -n '{terminal_id:"TM", workstream:"m", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TM CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-miss\",\"cwd\":\"$proj\"}")
  assert "V2-PROG-MISSING: WARNING printed" "echo \"\$out\" | grep -q 'WARNING'"
  rm -rf "$proj"
}
run_v2_progress_missing

run_v2_envvar_existing() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"existing", display_name:"E", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/existing.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TENV term_hash)
  WORKSTREAM=existing USER=u CLAUDE_TERMINAL_ID=TENV CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-env\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-ENV-EXIST: terminals/<hash> bound to env workstream" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'existing' ]"
  rm -rf "$proj"
}
run_v2_envvar_existing

run_v2_envvar_create() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TNEW term_hash)
  local out
  out=$(WORKSTREAM=brand-new USER=u CLAUDE_TERMINAL_ID=TNEW CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-new\",\"cwd\":\"$proj\"}")
  assert "V2-ENV-CREATE: workstreams/brand-new.json created" "[ -f '$tracking/workstreams/brand-new.json' ]"
  assert "V2-ENV-CREATE: terminal bound to brand-new" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'brand-new' ]"
  assert "V2-ENV-CREATE: user note printed" "echo \"\$out\" | grep -qi 'creating'"
  rm -rf "$proj"
}
run_v2_envvar_create

run_v2_envvar_invalid() {
  local proj; proj=$(mkv2)
  local out
  local rc
  out=$(WORKSTREAM='../oops' USER=u CLAUDE_TERMINAL_ID=TBAD CLAUDE_PROJECT_DIR="$proj" \
    bash "$SS" <<<"{\"session_id\":\"sid-bad\",\"cwd\":\"$proj\"}" 2>&1)
  rc=$?
  assert "V2-ENV-INVALID: non-zero exit" "[ $rc -ne 0 ]"
  assert "V2-ENV-INVALID: error message printed" "echo \"\$out\" | grep -qi 'rejected'"
  rm -rf "$proj"
}
run_v2_envvar_invalid

run_v2_other_ws() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"current", display_name:"Current", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/current.json"
  jq -n '{workstream:"other-1", display_name:"Other 1", progress_file:"", phase:"unknown", updated_at:"2026-05-04T00:00:00Z"}' \
    > "$tracking/workstreams/other-1.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TOW term_hash)
  jq -n '{terminal_id:"TOW", workstream:"current", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  local out
  out=$(USER=u CLAUDE_TERMINAL_ID=TOW CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sid-ow\",\"cwd\":\"$proj\"}")
  assert "V2-OTHER: lists other-1" "echo \"\$out\" | grep -q 'other-1'"
  assert "V2-OTHER: excludes current" "! echo \"\$out\" | grep -E 'switch.*current'"
  rm -rf "$proj"
}
run_v2_other_ws

run_v2_agent_a() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  # Spawner pre-created per-session tracking
  jq -n '{session_id:"sub-1", label:"sub-1", started_at:"2026-05-06T00:00:00Z", branch:"main", cwd:"'"$proj"'", is_worktree:false, workstream:"spawned", scope:{paths:[],mode:"exclusive"}, files:[], progress_file:null}' \
    > "$tracking/sub-1.json"
  echo "$tracking/sub-1.json" > "/tmp/claude-session-tracking-sub-1"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TAGT term_hash)
  local before_term_count
  before_term_count=$(find "$tracking/terminals" -name "*.json" 2>/dev/null | wc -l)
  AGENT_SESSION_ID=sub-1 USER=u CLAUDE_TERMINAL_ID=TAGT CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sub-1\",\"cwd\":\"$proj\"}" >/dev/null
  local after_term_count
  after_term_count=$(find "$tracking/terminals" -name "*.json" 2>/dev/null | wc -l)
  assert "V2-AGENT-A: terminals/<hash>.json NOT written" "[ '$after_term_count' = '$before_term_count' ]"
  rm -f "/tmp/claude-session-tracking-sub-1"
  rm -rf "$proj"
}
run_v2_agent_a

run_v2_agent_b_ok() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"parent-ws", display_name:"P", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/parent-ws.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TPAR term_hash)
  jq -n '{terminal_id:"TPAR", workstream:"parent-ws", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # NO pre-created tracking (rm pointer) - forces Case B
  rm -f "/tmp/claude-session-tracking-sub-b"
  AGENT_SESSION_ID=sub-b USER=u CLAUDE_TERMINAL_ID=TPAR CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<"{\"session_id\":\"sub-b\",\"cwd\":\"$proj\"}" >/dev/null
  # Subagent should have created its own per-session tracking with parent-ws
  assert "V2-AGENT-B-OK: per-session tracking workstream = parent-ws" \
    "find $tracking -maxdepth 1 -name '*.json' -newer $tracking/workstreams/parent-ws.json | xargs -I{} jq -r .workstream {} | grep -q 'parent-ws'"
  # Parent's terminal_state untouched
  assert "V2-AGENT-B-OK: parent terminal_state.workstream unchanged" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'parent-ws' ]"
  rm -rf "$proj"
}
run_v2_agent_b_ok

run_v2_agent_b_no_parent() {
  local proj; proj=$(mkv2)
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local rc out
  out=$(AGENT_SESSION_ID=sub-x USER=u CLAUDE_TERMINAL_ID=TNOP CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$proj/docs/sessions/.tracking" \
    bash "$SS" <<<"{\"session_id\":\"sub-x\",\"cwd\":\"$proj\"}" 2>&1)
  rc=$?
  assert "V2-AGENT-B-NOPARENT: exit non-zero" "[ $rc -ne 0 ]"
  rm -rf "$proj"
}
run_v2_agent_b_no_parent

run_v2_rebind_survives() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"old-ws", display_name:"O", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/old-ws.json"
  jq -n '{workstream:"new-ws", display_name:"N", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/new-ws.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TRBN term_hash)
  # Per-session tracking has OLD workstream (session started bound to old-ws)
  jq -n '{session_id:"sid-rb", label:"r", started_at:"2026-05-05T00:00:00Z", branch:"main", cwd:"'"$proj"'", is_worktree:false, workstream:"old-ws", scope:{paths:[],mode:"exclusive"}, files:[], progress_file:null}' \
    > "$tracking/r.json"
  echo "$tracking/r.json" > "/tmp/claude-session-tracking-sid-rb"
  # resume/rebind: terminal_state now points to new-ws
  jq -n '{terminal_id:"TRBN", workstream:"new-ws", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # Now simulate a checkpoint write
  echo "# progress" > "$proj/docs/sessions/progress-new-ws.md"
  touch "/tmp/baton-pending-sid-rb"
  echo '{"session_id":"sid-rb","cwd":"'"$proj"'","tool_input":{"file_path":"'"$proj"'/docs/sessions/progress-new-ws.md"}}' \
    | BATON_DIR="$tracking" USER=u CLAUDE_TERMINAL_ID=TRBN CLAUDE_PROJECT_DIR="$proj" bash "$CP" >/dev/null 2>&1
  # Assert NEW-WS got updated, not OLD-WS
  assert "V2-REBIND: new-ws.progress_file populated" \
    "[ -n \"\$(jq -r .progress_file '$tracking/workstreams/new-ws.json')\" ]"
  assert "V2-REBIND: old-ws.progress_file unchanged (empty)" \
    "[ \"\$(jq -r .progress_file '$tracking/workstreams/old-ws.json')\" = '' ]"
  rm -f "/tmp/baton-pending-sid-rb" "/tmp/baton-done-sid-rb" "/tmp/claude-session-tracking-sid-rb"
  rm -rf "$proj"
}
run_v2_rebind_survives

# V2-REBIND-CC: resume/rebind propagates to context-checkpoint.sh (PreToolUse).
# Regression: before commit X, context-checkpoint read workstream only from the
# v1 POINTER→T_FILE chain, which a bare rebind doesn't update. The PreToolUse hook
# would emit a checkpoint path for the OLD workstream while the write-trigger
# (already on v2) wrote under the NEW one, tripping the cross-workstream guard.
run_v2_rebind_cc_survives() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"old-ws", display_name:"O", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/old-ws.json"
  jq -n '{workstream:"new-ws", display_name:"N", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/new-ws.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TCC term_hash)
  # Per-session T_FILE still names OLD workstream (session started bound to old-ws)
  local sid="sid-cc-rb"
  jq -n '{session_id:"'"$sid"'", workstream:"old-ws"}' > "$tracking/old-t.json"
  echo "$tracking/old-t.json" > "/tmp/claude-session-tracking-${sid}"
  # resume/rebind: terminal_state now points to new-ws
  jq -n '{terminal_id:"TCC", workstream:"new-ws", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # Trigger checkpoint (35% > default 20% threshold)
  echo "35" > "/tmp/claude-context-pct-${sid}"
  # Run context-checkpoint
  local out
  out=$(echo '{"session_id":"'"$sid"'","cwd":"'"$proj"'","tool_name":"Bash"}' \
    | BATON_DIR="$tracking" USER=u CLAUDE_TERMINAL_ID=TCC CLAUDE_PROJECT_DIR="$proj" bash "$CC" 2>/dev/null)
  # The additionalContext payload should reference progress-new-ws-*, NOT progress-old-ws-*
  assert "V2-REBIND-CC: PreToolUse path uses new workstream" \
    "echo \"\$out\" | grep -q 'progress-new-ws-'"
  assert "V2-REBIND-CC: PreToolUse path does not use old workstream" \
    "! echo \"\$out\" | grep -q 'progress-old-ws-'"
  rm -f "/tmp/claude-session-tracking-${sid}" "/tmp/claude-context-pct-${sid}" \
        "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" \
        "/tmp/baton-archive-${sid}"
  rm -rf "$proj"
}
run_v2_rebind_cc_survives

# E4: the checkpoint gate fires at the compiled default (BATON_DEFAULT_PCT_THRESHOLD=20).
# Sandbox the config FIRST so the default-20 premise is not inherited from the runner env.
run_e4_threshold_boundary() {
  export XDG_CONFIG_HOME="$(mktemp -d)/cfg"; mkdir -p "$XDG_CONFIG_HOME/baton"
  echo '{}' > "$XDG_CONFIG_HOME/baton/config.json"
  unset BATON_PCT_THRESHOLD
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"e4-ws", display_name:"E4", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/e4-ws.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TE4 term_hash)
  jq -n '{terminal_id:"TE4", workstream:"e4-ws", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  # Drive the SAME hook twice with a fresh sid each, varying only the pct.
  local sid pct out
  # pct=20 fires (20 -lt 20 is false -> gate proceeds, injects progress- payload)
  sid="sid-e4-20"; pct=20
  jq -n '{session_id:"'"$sid"'", workstream:"e4-ws"}' > "$tracking/e4-t-${sid}.json"
  echo "$tracking/e4-t-${sid}.json" > "/tmp/claude-session-tracking-${sid}"
  echo "$pct" > "/tmp/claude-context-pct-${sid}"
  out=$(echo '{"session_id":"'"$sid"'","cwd":"'"$proj"'","tool_name":"Bash"}' \
    | BATON_DIR="$tracking" USER=u CLAUDE_TERMINAL_ID=TE4 CLAUDE_PROJECT_DIR="$proj" bash "$CC" 2>/dev/null)
  assert "E4-BOUNDARY: gate fires at default threshold (pct=20)" \
    "echo \"\$out\" | grep -q 'progress-'"
  rm -f "/tmp/claude-session-tracking-${sid}" "/tmp/claude-context-pct-${sid}" \
        "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" \
        "/tmp/baton-archive-${sid}"
  # pct=19 does NOT fire (19 -lt 20 is true -> early exit, empty injection)
  sid="sid-e4-19"; pct=19
  jq -n '{session_id:"'"$sid"'", workstream:"e4-ws"}' > "$tracking/e4-t-${sid}.json"
  echo "$tracking/e4-t-${sid}.json" > "/tmp/claude-session-tracking-${sid}"
  echo "$pct" > "/tmp/claude-context-pct-${sid}"
  out=$(echo '{"session_id":"'"$sid"'","cwd":"'"$proj"'","tool_name":"Bash"}' \
    | BATON_DIR="$tracking" USER=u CLAUDE_TERMINAL_ID=TE4 CLAUDE_PROJECT_DIR="$proj" bash "$CC" 2>/dev/null)
  assert "E4-BOUNDARY: gate does not fire below default threshold (pct=19)" \
    "! echo \"\$out\" | grep -q 'progress-'"
  rm -f "/tmp/claude-session-tracking-${sid}" "/tmp/claude-context-pct-${sid}" \
        "/tmp/claude-context-triggered-${sid}" "/tmp/baton-pending-${sid}" \
        "/tmp/baton-archive-${sid}"
  rm -rf "$proj"
}
run_e4_threshold_boundary

run_v2_pd_agent_exit() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"pd-ws", display_name:"Original", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/pd-ws.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TPD term_hash)
  jq -n '{terminal_id:"TPD", workstream:"pd-ws", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n '{session_id:"sub-pd", workstream:"pd-ws"}' > "$tracking/sub-pd.json"
  echo "$tracking/sub-pd.json" > "/tmp/claude-session-tracking-sub-pd"
  mkdir -p "$proj/proj-someproject"
  ln -s "$proj/proj-someproject" "$proj/projects/someproject"
  AGENT_SESSION_ID=sub-pd USER=u CLAUDE_TERMINAL_ID=TPD CLAUDE_PROJECT_DIR="$proj" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"sub-pd\",\"prompt\":\"working on someproject\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-PD-AGENT: workstreams/pd-ws.display_name unchanged (early-exit honored)" \
    "[ \"\$(jq -r .display_name '$tracking/workstreams/pd-ws.json')\" = 'Original' ]"
  rm -f "/tmp/claude-session-tracking-sub-pd"
  rm -rf "$proj"
}
run_v2_pd_agent_exit

run_v2_pd_writes_workstreams() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"pd2", display_name:"", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/pd2.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th
  th=$(USER=u CLAUDE_TERMINAL_ID=TPD2 term_hash)
  jq -n '{terminal_id:"TPD2", workstream:"pd2", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n '{session_id:"sid-pd2", workstream:"pd2"}' > "$tracking/sid-pd2.json"
  echo "$tracking/sid-pd2.json" > "/tmp/claude-session-tracking-sid-pd2"
  mkdir -p "$proj/proj-someproject"
  ln -s "$proj/proj-someproject" "$proj/projects/someproject"
  USER=u CLAUDE_TERMINAL_ID=TPD2 CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"sid-pd2\",\"prompt\":\"working on someproject\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-PD-WRITE: display_name set on workstreams/pd2.json" \
    "[ \"\$(jq -r .display_name '$tracking/workstreams/pd2.json')\" = 'someproject' ]"
  assert "V2-PD-WRITE: per-session tracking display_name absent" \
    "[ \"\$(jq -r '.display_name // \"\"' '$tracking/sid-pd2.json')\" = '' ]"
  rm -f "/tmp/claude-session-tracking-sid-pd2"
  rm -rf "$proj"
}
run_v2_pd_writes_workstreams

# V2-PD-REBIND: mention of a project already owned by a DIFFERENT workstream
# rebinds this terminal to it (terminals/<hash>.json) and leaves the bound
# workstream's label untouched. This is the /clear-binding-bug fix.
run_v2_pd_rebind() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"cur", display_name:"alpha", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/cur.json"
  jq -n '{workstream:"ckpt", display_name:"baton", progress_file:"", phase:"unknown", updated_at:"2026-05-06T00:00:00Z"}' \
    > "$tracking/workstreams/ckpt.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=TRBD term_hash)
  jq -n '{terminal_id:"TRBD", workstream:"cur", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n '{session_id:"sid-rbd", workstream:"cur"}' > "$tracking/sid-rbd.json"
  echo "$tracking/sid-rbd.json" > "/tmp/claude-session-tracking-sid-rbd"
  mkdir -p "$proj/proj-baton"
  ln -s "$proj/proj-baton" "$proj/projects/baton"
  USER=u CLAUDE_TERMINAL_ID=TRBD CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"sid-rbd\",\"prompt\":\"let us work on baton now\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-PD-REBIND: terminal rebound to owning workstream" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'ckpt' ]"
  assert "V2-PD-REBIND: bound workstream label unchanged" \
    "[ \"\$(jq -r .display_name '$tracking/workstreams/cur.json')\" = 'alpha' ]"
  rm -f "/tmp/claude-session-tracking-sid-rbd"
  rm -rf "$proj"
}
run_v2_pd_rebind

# V2-PD-CLAIM: mention of a project NO workstream owns claims the name for the
# bound workstream with NO numeric suffix, and does NOT flip the binding.
run_v2_pd_claim_no_suffix() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"cur", display_name:"alpha", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/cur.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=TCLM term_hash)
  jq -n '{terminal_id:"TCLM", workstream:"cur", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n '{session_id:"sid-clm", workstream:"cur"}' > "$tracking/sid-clm.json"
  echo "$tracking/sid-clm.json" > "/tmp/claude-session-tracking-sid-clm"
  mkdir -p "$proj/proj-beta"
  ln -s "$proj/proj-beta" "$proj/projects/beta"
  USER=u CLAUDE_TERMINAL_ID=TCLM CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"sid-clm\",\"prompt\":\"work on beta\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-PD-CLAIM: bound workstream renamed (no suffix)" \
    "[ \"\$(jq -r .display_name '$tracking/workstreams/cur.json')\" = 'beta' ]"
  assert "V2-PD-CLAIM: binding not flipped" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'cur' ]"
  rm -f "/tmp/claude-session-tracking-sid-clm"
  rm -rf "$proj"
}
run_v2_pd_claim_no_suffix

# V2-PD-RENAME-SUFFIX: explicit "rename this session to X" keeps suffix
# disambiguation when another workstream already owns X (binding unchanged).
run_v2_pd_rename_suffix() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  jq -n '{workstream:"cur", display_name:"alpha", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/cur.json"
  jq -n '{workstream:"o2", display_name:"beta", progress_file:"", phase:"unknown", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/workstreams/o2.json"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=TRNS term_hash)
  jq -n '{terminal_id:"TRNS", workstream:"cur", updated_at:"2026-05-05T00:00:00Z"}' \
    > "$tracking/terminals/${th}.json"
  jq -n '{session_id:"sid-rns", workstream:"cur"}' > "$tracking/sid-rns.json"
  echo "$tracking/sid-rns.json" > "/tmp/claude-session-tracking-sid-rns"
  USER=u CLAUDE_TERMINAL_ID=TRNS CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tracking" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"sid-rns\",\"prompt\":\"rename this session to beta\",\"cwd\":\"$proj\"}" >/dev/null
  assert "V2-PD-RENAME-SUFFIX: collision suffixed to beta-2" \
    "[ \"\$(jq -r .display_name '$tracking/workstreams/cur.json')\" = 'beta-2' ]"
  assert "V2-PD-RENAME-SUFFIX: binding unchanged" \
    "[ \"\$(jq -r .workstream '$tracking/terminals/${th}.json')\" = 'cur' ]"
  rm -f "/tmp/claude-session-tracking-sid-rns"
  rm -rf "$proj"
}
run_v2_pd_rename_suffix

run_t_cc3_simple() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj
  proj=$(mkproj)

  # checkpoint_threshold default + override
  unset BATON_PCT_THRESHOLD
  assert "cc3-threshold-default" '[ "$(checkpoint_threshold)" = "20" ]'
  BATON_PCT_THRESHOLD=42 assert "cc3-threshold-env" '[ "$(BATON_PCT_THRESHOLD=42 checkpoint_threshold)" = "42" ]'

  # checkpoint_dir default + override
  unset BATON_DIR
  assert "cc3-dir-default" '[ "$(checkpoint_dir "$proj")" = "$proj/.baton" ]'
  BATON_DIR=/tmp/cd-$$ assert "cc3-dir-env" '[ "$(BATON_DIR=/tmp/cd-$$ checkpoint_dir "$proj")" = "/tmp/cd-$$" ]'

  # checkpoint_progress_dir default + override
  unset BATON_PROGRESS_DIR
  local cd; cd=$(checkpoint_dir "$proj")
  assert "cc3-progress-default" '[ "$(checkpoint_progress_dir "$proj")" = "$cd/progress" ]'
  BATON_PROGRESS_DIR=/tmp/pp-$$ assert "cc3-progress-env" '[ "$(BATON_PROGRESS_DIR=/tmp/pp-$$ checkpoint_progress_dir "$proj")" = "/tmp/pp-$$" ]'

  # archive_dir default (XDG) + override
  unset BATON_ARCHIVE_DIR
  assert "cc3-archive-default" '[ "$(archive_dir)" = "$HOME/.local/share/baton" ]'
  BATON_ARCHIVE_DIR=/mnt/big/archives assert "cc3-archive-env" '[ "$(BATON_ARCHIVE_DIR=/mnt/big/archives archive_dir)" = "/mnt/big/archives" ]'

  # ttl helpers
  unset BATON_WORKSTREAM_TTL_DAYS BATON_TRACKING_TTL_DAYS BATON_TMP_TTL_HOURS
  assert "cc3-ws-ttl-default" '[ "$(workstream_ttl_seconds)" = "$((30*86400))" ]'
  assert "cc3-tracking-ttl-default" '[ "$(tracking_ttl_seconds)" = "$((7*86400))" ]'
  assert "cc3-tmp-ttl-default" '[ "$(tmp_ttl_minutes)" = "$((24*60))" ]'
  BATON_WORKSTREAM_TTL_DAYS=14 assert "cc3-ws-ttl-env" '[ "$(BATON_WORKSTREAM_TTL_DAYS=14 workstream_ttl_seconds)" = "$((14*86400))" ]'

  rm -rf "$proj"
}
run_t_cc3_simple

run_t_parse_iso8601() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mkproj)
  local now; now=$(date -u +%s)

  # Valid ISO 8601 → epoch seconds within 5s of the original
  local ts="2026-05-10T12:00:00Z"
  local got
  got=$(parse_iso8601 "$ts")
  assert "parse-iso-valid" '[ "$got" = "1778414400" ]'

  # Malformed → returns now - workstream_ttl + 86400 (24h grace)
  local fallback_expected=$((now - $(workstream_ttl_seconds) + 86400))
  got=$(parse_iso8601 "garbage")
  # Allow 5s drift since `now` re-evaluates inside helper
  assert "parse-iso-malformed-grace" "[ \$((got - fallback_expected)) -ge -5 ] && [ \$((got - fallback_expected)) -le 5 ]"

  # Empty → same fallback
  got=$(parse_iso8601 "")
  assert "parse-iso-empty-grace" "[ \$((got - fallback_expected)) -ge -5 ] && [ \$((got - fallback_expected)) -le 5 ]"

  # Future > now+86400 → fallback
  local future; future=$(date -u -d "+5 days" +%Y-%m-%dT%H:%M:%SZ)
  got=$(parse_iso8601 "$future")
  assert "parse-iso-future-grace" "[ \$((got - fallback_expected)) -ge -5 ] && [ \$((got - fallback_expected)) -le 5 ]"

  rm -rf "$proj"
}
run_t_parse_iso8601

run_t_atomic_write() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mkproj)
  local target="$proj/.tracking/foo.json"
  mkdir -p "$proj/.tracking"

  # Happy path: writes and renames
  echo '{"a":1}' | atomic_write "$target"
  assert "atomic-write-creates" '[ -f "$target" ]'
  assert "atomic-write-content" '[ "$(jq -r .a "$target")" = "1" ]'

  # No leftover .tmp.$$ file
  assert "atomic-write-no-tmp-leftover" '[ -z "$(ls "$proj/.tracking/"*.tmp.* 2>/dev/null)" ]'

  # Overwrite path: existing file replaced atomically
  echo '{"a":2}' | atomic_write "$target"
  assert "atomic-write-overwrite" '[ "$(jq -r .a "$target")" = "2" ]'

  rm -rf "$proj"
}
run_t_atomic_write

run_t_workstream_in_use() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  mkdir -p "$tracking/terminals" "$tracking/workstreams"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)

  # Fresh terminal references ws-A → in use
  jq -n --arg ws "ws-A" --arg ts "$now" '{terminal_id:"t1", workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/t1.json"
  assert "in-use-fresh" 'workstream_in_use "$tracking" ws-A'
  assert "in-use-fresh-rc" 'workstream_in_use "$tracking" ws-A; [ $? -eq 0 ]'

  # No terminal references ws-B → not in use
  assert "in-use-none-rc" '! workstream_in_use "$tracking" ws-B'

  # Only stale terminal references ws-C → not in use (terminal is dead)
  jq -n --arg ws "ws-C" --arg ts "$stale" '{terminal_id:"t2", workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/t2.json"
  assert "in-use-stale-only-rc" '! workstream_in_use "$tracking" ws-C'

  rm -rf "$proj"
}
run_t_workstream_in_use

run_t_archive_helpers() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mkproj)
  local tracking="$proj/docs/sessions/.tracking"
  local archive="$proj/archive-base"
  mkdir -p "$tracking/workstreams" "$archive"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local ws_file="$tracking/workstreams/ws-X.json"
  jq -n --arg ws "ws-X" --arg ts "$now" \
    '{workstream:$ws, display_name:"x", progress_file:"", phase:"unknown", updated_at:$ts}' \
    > "$ws_file"

  archive_workstream "$tracking" "$archive" "$ws_file"
  assert "archive-ws-source-gone" '[ ! -f "$ws_file" ]'
  local ym; ym=$(date +%Y-%m)
  assert "archive-ws-dest-exists" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-X.json" ]'

  # Collision-safe: write a duplicate, archive again
  jq -n --arg ws "ws-X" --arg ts "$now" \
    '{workstream:$ws, display_name:"x2", progress_file:"", phase:"unknown", updated_at:$ts}' \
    > "$ws_file"
  archive_workstream "$tracking" "$archive" "$ws_file"
  assert "archive-ws-collision-suffix" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-X.json.1" ]'

  # Per-session tracking
  local tf="$tracking/main-20260510-120000.json"
  echo '{}' > "$tf"
  archive_session_tracking "$tracking" "$archive" "$tf"
  assert "archive-tracking-source-gone" '[ ! -f "$tf" ]'
  assert "archive-tracking-dest-exists" '[ -f "$archive/checkpoint-state/$ym/sessions-tracking/main-20260510-120000.json" ]'

  rm -rf "$proj"
}
run_t_archive_helpers

run_t_session_start_atomic() {
  local proj; proj=$(mkproj)
  local sid="sess-atomic-$$"

  run_session_start "$proj" "term-atomic" "$sid" >/dev/null 2>&1

  # No leftover .tmp.$$ files in tracking dirs (atomic_write cleans up on success
  # via mv; on failure it rms the tmp explicitly).
  local leftover
  leftover=$(find "$proj/docs/sessions/.tracking" -name "*.tmp.*" 2>/dev/null | wc -l)
  assert "session-start-no-tmp-leftover" '[ "$leftover" = "0" ]'

  rm -rf "$proj"
}
run_t_session_start_atomic

run_t_session_start_no_direct_writes() {
  # Ensure no direct redirect writes remain to .tracking/workstreams/ or .tracking/terminals/.
  # All such writes must go through atomic_write per T3.
  local hits
  hits=$(grep -nE '> "?\$TRACKING/(workstreams|terminals)/' "$HOOKS_DIR/session-start.sh" | grep -v 'atomic_write')
  assert "session-start-no-direct-redirect" '[ -z "$hits" ]'

  # tmp.$$ + mv pattern also disallowed (subsumed by atomic_write)
  local hits2
  hits2=$(grep -n '\.tmp[^"]* &&' "$HOOKS_DIR/session-start.sh")
  assert "session-start-no-manual-tmp-mv" '[ -z "$hits2" ]'

  # F2 enforcement: no destructive find in session-start.sh.
  # Prunes belong only in cleanup-cron.sh per CC4.
  local hits3
  hits3=$(grep -nE 'find[^|]*-delete' "$HOOKS_DIR/session-start.sh")
  assert "session-start-no-find-delete" '[ -z "$hits3" ]'
}
run_t_session_start_no_direct_writes

run_t_session_start_project_dir() {
  local proj; proj=$(mkproj)
  local sid="sess-pd-$$"
  run_session_start "$proj" "term-pd" "$sid" >/dev/null 2>&1

  # The created workstream record must have project_dir = $proj
  local ws_file
  ws_file=$(find "$proj/docs/sessions/.tracking/workstreams" -maxdepth 1 -name "*.json" | head -1)
  assert "session-start-ws-file-exists" '[ -n "$ws_file" ] && [ -f "$ws_file" ]'
  local pd
  pd=$(jq -r '.project_dir // empty' "$ws_file")
  assert "session-start-project-dir-set" '[ "$pd" = "$proj" ]'

  rm -rf "$proj"
}
run_t_session_start_project_dir

run_t_atomic_terminal_write() {
  local proj; proj=$(mkproj)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run_session_start "$proj" "term-atomic-race" "sid-r-$i" >/dev/null 2>&1 &
  done
  wait
  # All terminals/<hash>.json files must parse cleanly
  local bad=0
  for f in "$proj/docs/sessions/.tracking/terminals"/*.json; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || bad=$((bad+1))
  done
  assert "atomic-terminal-no-corrupt-under-race" '[ "$bad" = "0" ]'

  rm -rf "$proj"
}
run_t_atomic_terminal_write

run_t_cron_blocks() {
  local proj; proj=$(mkproj)
  # Mimic the layout cleanup-cron.sh expects (checkpoint_dir → .baton).
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" \
           "$proj/docs/archive" "$proj/.claude/hooks/lib"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"
  mkdir -p "$archive"

  local now stale fresh
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  fresh=$(date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)

  # Stale workstream, no terminal pointer → should archive
  jq -n --arg ws "ws-stale" --arg ts "$stale" \
    '{workstream:$ws, display_name:"s", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-stale.json"

  # Stale workstream, fresh terminal → should NOT archive (in-use skip)
  jq -n --arg ws "ws-pinned" --arg ts "$stale" \
    '{workstream:$ws, display_name:"p", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-pinned.json"
  jq -n --arg ws "ws-pinned" --arg ts "$now" \
    '{terminal_id:"t1", workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/t1.json"

  # Stale workstream + only-stale terminal → IS archived (V2 - stale pointers don't pin)
  jq -n --arg ws "ws-stale-ptr" --arg ts "$stale" \
    '{workstream:$ws, display_name:"sp", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-stale-ptr.json"
  jq -n --arg ws "ws-stale-ptr" --arg ts "$stale" \
    '{terminal_id:"t-old", workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/t-old.json"

  # Fresh workstream → not archived
  jq -n --arg ws "ws-fresh" --arg ts "$fresh" \
    '{workstream:$ws, display_name:"f", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-fresh.json"

  # Run cron with overrides
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  local ym; ym=$(date +%Y-%m)

  assert "cron-archives-stale" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-stale.json" ] && [ ! -f "$tracking/workstreams/ws-stale.json" ]'
  assert "cron-skips-in-use" '[ -f "$tracking/workstreams/ws-pinned.json" ]'
  assert "cron-stale-ptr-no-pin" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-stale-ptr.json" ]'
  assert "cron-fresh-stays" '[ -f "$tracking/workstreams/ws-fresh.json" ]'
  assert "cron-block6-touch" '[ -f "$proj/.baton/.cron-last-run" ] || [ -f "$proj/docs/sessions/.tracking/.cron-last-run" ]'

  rm -rf "$proj"
}
run_t_cron_blocks

# Regression: by-reference install - PROJECT_DIR holds session data but NO copy
# of the lib (the real-world by-reference layout). The script must self-locate its lib
# relative to its own path, archive normally, and never silently no-op.
run_t_cron_lib_not_under_project_dir() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals"
  # Deliberately do NOT create "$proj/.claude/hooks/lib" or copy the lib.

  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "ws-ref" --arg ts "$stale" \
    '{workstream:$ws, display_name:"r", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-ref.json"
  local archive="$proj/archive-base"; mkdir -p "$archive"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"
  local rc=$?

  local ym; ym=$(date +%Y-%m)
  assert "cron-byref-exit-ok" '[ "$rc" = "0" ]'
  assert "cron-byref-archives-stale" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-ref.json" ]'
  assert "cron-byref-block6-touch" '[ -f "$proj/.baton/.cron-last-run" ]'
  rm -rf "$proj"
}
run_t_cron_lib_not_under_project_dir

run_t_cron_archive_order() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" \
           "$proj/.claude/hooks/lib" "$proj/docs/archive"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"

  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)

  # Stale workstream + stale terminal pointing at it.
  # If Block 3 (terminal delete) ran AFTER Block 4 (workstream archive),
  # the terminal would still pin the workstream → workstream stays.
  # Correct order (Block 3 before Block 4) → terminal deleted → in_use false → workstream archived.
  jq -n --arg ws "ws-order" --arg ts "$stale" \
    '{workstream:$ws, display_name:"o", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-order.json"
  # Make the terminal file old enough for Block 3's 72h cutoff (mtime).
  jq -n --arg ws "ws-order" --arg ts "$stale" \
    '{terminal_id:"t-order", workstream:$ws, updated_at:$ts}' \
    > "$tracking/terminals/t-order.json"
  touch -d "5 days ago" "$tracking/terminals/t-order.json"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  local ym; ym=$(date +%Y-%m)
  assert "cron-archive-order-correct" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-order.json" ]'

  rm -rf "$proj"
}
run_t_cron_archive_order

run_t_cron_malformed_updated_at() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" "$proj/.claude/hooks/lib" "$proj/docs/archive"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"

  # Malformed updated_at → 24h grace → archive-eligible on this run only if
  # grace expired. parse_iso8601 returns (now - workstream_ttl + 86400).
  # Cutoff is (now - workstream_ttl). Since fallback > cutoff by 86400,
  # the record is NOT archived on first run - survives 24h.
  jq -n --arg ws "ws-malformed" --arg ts "garbage" \
    '{workstream:$ws, display_name:"m", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-malformed.json"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  assert "cron-malformed-grace-survives-first-run" '[ -f "$tracking/workstreams/ws-malformed.json" ]'

  rm -rf "$proj"
}
run_t_cron_malformed_updated_at

run_t_cron_future_updated_at() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" "$proj/.claude/hooks/lib" "$proj/docs/archive"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"

  local future; future=$(date -u -d "+10 days" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "ws-future" --arg ts "$future" \
    '{workstream:$ws, display_name:"f", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-future.json"

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  assert "cron-future-grace-survives-first-run" '[ -f "$tracking/workstreams/ws-future.json" ]'

  rm -rf "$proj"
}
run_t_cron_future_updated_at

run_t_prune_flock() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" "$proj/.claude/hooks/lib" "$proj/docs/archive"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"

  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ws "ws-flock" --arg ts "$stale" \
    '{workstream:$ws, display_name:"l", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
    > "$tracking/workstreams/ws-flock.json"

  # Hold the lock from a separate process while cron runs; cron should block
  # in archive_workstream's flock 8 then succeed once we release.
  (
    exec 7>"$tracking/workstreams/ws-flock.json.lock"
    flock 7
    sleep 1.5
    flock -u 7
  ) &
  HOLDER=$!
  sleep 0.2

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" &
  CRON=$!

  wait "$HOLDER"
  wait "$CRON"

  local ym; ym=$(date +%Y-%m)
  assert "cron-flock-eventually-archives" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-flock.json" ]'

  rm -rf "$proj"
}
run_t_prune_flock

# --if-due self-throttle mode: safe to fire blindly every session.
# Gates on .cron-last-run marker age, holds a non-blocking flock for the run.
run_t_cron_if_due() {
  local proj; proj=$(mkproj)
  local tracking="$proj/.baton"
  mkdir -p "$tracking/workstreams" "$tracking/terminals" \
           "$proj/.claude/hooks/lib" "$proj/docs/archive"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"; mkdir -p "$archive"
  local logf="$proj/cron.log"

  local stale; stale=$(date -u -d "60 days ago" +%Y-%m-%dT%H:%M:%SZ)
  seed_stale_ws() {
    jq -n --arg ws "$1" --arg ts "$stale" \
      '{workstream:$ws, display_name:"s", progress_file:"", phase:"unknown", updated_at:$ts, project_dir:"x"}' \
      > "$tracking/workstreams/$1.json"
  }

  # (a) ABSENT marker + stale workstream → sweeps, archives, creates marker.
  seed_stale_ws ws-a
  rm -f "$tracking/.cron-last-run"
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  local ym; ym=$(date +%Y-%m)
  assert "cron-ifdue-absent-sweeps" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-a.json" ]'
  assert "cron-ifdue-absent-marker" '[ -f "$tracking/.cron-last-run" ]'

  # (b) AGED marker (50h) with default 48h interval → sweeps.
  seed_stale_ws ws-b
  touch -d "50 hours ago" "$tracking/.cron-last-run"
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  assert "cron-ifdue-aged-sweeps" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-b.json" ]'

  # (c) FRESH marker (1h) with default 48h interval → skips, archives nothing.
  seed_stale_ws ws-c
  touch -d "1 hour ago" "$tracking/.cron-last-run"
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  assert "cron-ifdue-fresh-skips" '[ -f "$tracking/workstreams/ws-c.json" ] && [ ! -f "$archive/checkpoint-state/$ym/workstreams/ws-c.json" ]'

  # (d) ROUND-TRIP: first --if-due run creates marker (Block 6), second skips.
  rm -f "$tracking/.cron-last-run"
  seed_stale_ws ws-d1
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  seed_stale_ws ws-d2
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  assert "cron-ifdue-roundtrip-first-sweeps" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-d1.json" ]'
  assert "cron-ifdue-roundtrip-second-skips" '[ -f "$tracking/workstreams/ws-d2.json" ] && [ ! -f "$archive/checkpoint-state/$ym/workstreams/ws-d2.json" ]'

  # (e) CONCURRENCY: hold the sweep lock; --if-due must skip immediately + log.
  rm -f "$tracking/.cron-last-run"
  seed_stale_ws ws-e
  : > "$logf"
  (
    exec 6>"$tracking/.sweep.lock"
    flock 6
    sleep 2
    flock -u 6
  ) &
  local holder=$!
  sleep 0.2
  local t0 t1
  t0=$(date +%s)
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  local rc=$?
  t1=$(date +%s)
  wait "$holder"
  assert "cron-ifdue-concurrency-exit0" '[ "$rc" = "0" ]'
  assert "cron-ifdue-concurrency-immediate" '[ "$((t1 - t0))" -lt 2 ]'
  assert "cron-ifdue-concurrency-skip-log" 'grep -q "sweep: in progress" "$logf"'
  assert "cron-ifdue-concurrency-no-archive" '[ -f "$tracking/workstreams/ws-e.json" ]'

  # (f) ENV-OVERRIDE: BATON_SWEEP_INTERVAL_HOURS=1.
  # marker aged 2h → due (sweeps); marker aged 20min → not due (skips).
  rm -f "$tracking/.cron-last-run"
  seed_stale_ws ws-f-due
  touch -d "2 hours ago" "$tracking/.cron-last-run"
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    BATON_SWEEP_INTERVAL_HOURS=1 \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  assert "cron-ifdue-env-2h-sweeps" '[ -f "$archive/checkpoint-state/$ym/workstreams/ws-f-due.json" ]'

  seed_stale_ws ws-f-skip
  touch -d "20 minutes ago" "$tracking/.cron-last-run"
  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" BATON_CRON_LOG="$logf" \
    BATON_SWEEP_INTERVAL_HOURS=1 \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh" --if-due
  assert "cron-ifdue-env-20min-skips" '[ -f "$tracking/workstreams/ws-f-skip.json" ] && [ ! -f "$archive/checkpoint-state/$ym/workstreams/ws-f-skip.json" ]'

  unset -f seed_stale_ws
  rm -rf "$proj"
}
run_t_cron_if_due

run_t_tmp_leak_coverage() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/.claude/hooks/lib"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local archive="$proj/archive-base"
  mkdir -p "$archive"

  # Unique tag so this test never touches another session's /tmp keys.
  local tag="leak-$$-${RANDOM}"
  local stale_files=(
    "/tmp/claude-context-pct-${tag}"
    "/tmp/baton-done-${tag}"
    "/tmp/baton-pending-${tag}"
    "/tmp/baton-archive-${tag}"
    "/tmp/claude-session-tracking-${tag}"
    "/tmp/claude-parent-sid-${tag}"
  )
  local fresh_file="/tmp/claude-context-pct-fresh-${tag}"

  for f in "${stale_files[@]}"; do
    touch "$f"
    touch -d "2 days ago" "$f"
  done
  touch "$fresh_file"   # mtime = now -> must survive the sweep

  OLORIN_PROJECT_DIR="$proj" OLORIN_ARCHIVE_DIR="$archive" \
    bash "$PROJECT_ROOT/tools/cleanup-cron.sh"

  local f
  for f in "${stale_files[@]}"; do
    local name; name=$(basename "$f")
    assert "tmp-leak-removed-${name}" '[ ! -e "$f" ]'
  done
  assert "tmp-leak-fresh-survives" '[ -e "$fresh_file" ]'

  rm -f "$fresh_file" "${stale_files[@]}"
  rm -rf "$proj"
}
run_t_tmp_leak_coverage

# ── cron / workstream-binding tests ─────────────────────────────────────────

# test-env-var-threading: BATON_DIR=/tmp/custom-$$ fully redirects tracking
run_t_env_var_threading() {
  local proj; proj=$(mktemp -d)
  mkdir -p "$proj/.claude/hooks/lib" "$proj/docs/sessions"
  cp "$HOOKS_DIR/lib/workstream-lib.sh" "$proj/.claude/hooks/lib/workstream-lib.sh"
  local custom_dir="/tmp/custom-ckpt-$$"
  mkdir -p "$custom_dir/workstreams" "$custom_dir/terminals"
  local sid="sid-evt-$$"

  BATON_DIR="$custom_dir" USER=u CLAUDE_TERMINAL_ID=TEVT CLAUDE_PROJECT_DIR="$proj" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\"}" >/dev/null

  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=TEVT term_hash)

  assert "evt-terminals-in-custom-dir" "[ -f '$custom_dir/terminals/${th}.json' ]"
  local ws; ws=$(jq -r .workstream "$custom_dir/terminals/${th}.json" 2>/dev/null)
  assert "evt-workstream-in-custom-dir" "[ -f '$custom_dir/workstreams/${ws}.json' ]"
  assert "evt-not-in-default-checkpoint" "[ ! -d '$proj/.baton' ]"
  assert "evt-not-in-legacy-tracking" "[ ! -d '$proj/docs/sessions/.tracking/terminals' ]"

  # Trigger a checkpoint write to produce a log_event entry under custom_dir
  local t_file="$custom_dir/evt-t.json"
  echo "{\"workstream\":\"${ws}\",\"display_name\":\"test\"}" > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  touch "/tmp/baton-pending-$sid"
  echo "# evt" > "$proj/docs/sessions/progress-${ws}-x.md"
  echo "{\"session_id\":\"$sid\",\"cwd\":\"$proj\",\"tool_input\":{\"file_path\":\"$proj/docs/sessions/progress-${ws}-x.md\"}}" \
    | BATON_DIR="$custom_dir" USER=u CLAUDE_TERMINAL_ID=TEVT CLAUDE_PROJECT_DIR="$proj" \
      bash "$CP" >/dev/null 2>&1
  assert "evt-log-event-in-custom-dir" "[ -f '$custom_dir/hook-events.jsonl' ]"

  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj" "$custom_dir"
}
run_t_env_var_threading

# test-progress-path-env: BATON_PROGRESS_DIR redirects checkpoint_progress_dir output
run_t_progress_path_env() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mktemp -d)
  local custom_prog="/tmp/custom-prog-$$"
  mkdir -p "$custom_prog"

  local pd
  pd=$(BATON_PROGRESS_DIR="$custom_prog" checkpoint_progress_dir "$proj")
  assert "progress-path-env-dir" '[ "$pd" = "$custom_prog" ]'

  unset BATON_PROGRESS_DIR
  local cd; cd=$(checkpoint_dir "$proj")
  local default_pd; default_pd=$(checkpoint_progress_dir "$proj")
  assert "progress-path-default" '[ "$default_pd" = "$cd/progress" ]'

  rm -rf "$proj" "$custom_prog"
}
run_t_progress_path_env

# test-display-name-env: BATON_DISPLAY_NAME wins over fallback; no symlink scan
run_t_display_name_env() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mktemp -d)
  mkdir -p "$proj/projects"
  # Plant a symlink that the OLD code would have walked - must NOT influence result
  local target; target=$(mktemp -d)
  ln -s "$target" "$proj/projects/gamma"

  local dn
  dn=$(BATON_DISPLAY_NAME=foo derive_display_name "$target" "$proj" "fallback-ws")
  assert "display-name-env-wins" '[ "$dn" = "foo" ]'

  unset BATON_DISPLAY_NAME
  dn=$(derive_display_name "$target" "$proj" "my-ws-id")
  assert "display-name-fallback-returned" '[ "$dn" = "my-ws-id" ]'

  rm -rf "$proj" "$target"
}
run_t_display_name_env

# test-log-event-path-honors-env: log_event writes to $BATON_DIR/hook-events.jsonl
run_t_log_event_path_honors_env() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local custom="/tmp/log-evt-$$"
  mkdir -p "$custom"
  BATON_DIR="$custom" log_event "$custom" test-hook test-event "key=val"
  assert "log-event-path-in-custom-dir" "[ -f '$custom/hook-events.jsonl' ]"
  rm -rf "$custom"
}
run_t_log_event_path_honors_env

# test-resolve-progress-no-symlink-walk: symlinked projects/ dir is NOT followed
run_t_resolve_progress_no_symlink_walk() {
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local proj; proj=$(mktemp -d)
  local custom_prog="/tmp/resolve-prog-$$"
  mkdir -p "$custom_prog"

  # Symlinked sub-project that has a progress file - OSS resolver must NOT find it
  local linked_proj; linked_proj=$(mktemp -d)
  mkdir -p "$linked_proj/docs/sessions"
  echo "# decoy" > "$linked_proj/docs/sessions/progress-myws-decoy.md"
  mkdir -p "$proj/projects"
  ln -s "$linked_proj" "$proj/projects/sub"

  # Real progress file in the configured progress dir
  echo "# real" > "$custom_prog/progress-myws-real.md"

  local resolved
  resolved=$(BATON_PROGRESS_DIR="$custom_prog" \
    resolve_progress_file "" "$proj" "myws" "")
  assert "resolve-no-symlink-not-decoy" '[ "$resolved" = "$custom_prog/progress-myws-real.md" ]'
  assert "resolve-no-symlink-finds-real" '[ -n "$resolved" ]'

  rm -rf "$proj" "$linked_proj" "$custom_prog"
}
run_t_resolve_progress_no_symlink_walk

run_corrupt_workstream_env_rejected() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"
  # Plant corrupt JSON
  echo "{not valid json" > "$tracking/workstreams/bad-ws.json"
  local out err rc
  err=$(mktemp)
  out=$(WORKSTREAM=bad-ws USER=u CLAUDE_TERMINAL_ID=CRW CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<'{"session_id":"sid-corr","cwd":"'"$proj"'"}' 2>"$err")
  rc=$?
  assert "CORRUPT-WS: exit code is 1" "[ $rc -eq 1 ]"
  assert "CORRUPT-WS: stderr matches exact format" \
    "grep -q '^WORKSTREAM=bad-ws but workstreams/bad-ws.json is corrupt:' '$err'"
  rm -f "$err"; rm -rf "$proj"
}
run_corrupt_workstream_env_rejected

run_cron_probe_warning() {
  local proj; proj=$(mkv2)
  local tracking="$proj/docs/sessions/.tracking"

  # Case 1: no .cron-last-run → warning
  local out1
  out1=$(USER=u CLAUDE_TERMINAL_ID=CP1 CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<'{"session_id":"sid-cp1","cwd":"'"$proj"'"}' 2>&1)
  assert "CRON-PROBE: warning when marker absent" \
    "echo \"\$out1\" | grep -q 'automatic sweep has just been launched'"

  # Case 2: fresh .cron-last-run → no warning
  touch "$tracking/.cron-last-run"
  local out2
  out2=$(USER=u CLAUDE_TERMINAL_ID=CP2 CLAUDE_PROJECT_DIR="$proj" \
    BATON_DIR="$tracking" \
    bash "$SS" <<<'{"session_id":"sid-cp2","cwd":"'"$proj"'"}' 2>&1)
  assert "CRON-PROBE: no warning when marker fresh" \
    "! echo \"\$out2\" | grep -q 'automatic sweep has just been launched'"

  rm -rf "$proj"

  # Cases 3-5 each use a FRESH proj/tracking. session-start.sh fires a detached
  # `cleanup-cron.sh --if-due` sweep that touches `.cron-last-run` to now (Block 6);
  # a sibling case's lingering sweep would otherwise clobber the deliberately-aged
  # marker before the next case's probe reads it (a 50h marker reset to 0h →
  # spurious silent). Per-case isolation makes the threshold assertions deterministic.

  # Case 3: marker ~97h old (default grace 96h + 1) → stale, hours-unit warning
  local proj3; proj3=$(mkv2); local tracking3="$proj3/docs/sessions/.tracking"
  touch -d "@$(( $(date -u +%s) - 97*3600 ))" "$tracking3/.cron-last-run"
  local out3
  out3=$(USER=u CLAUDE_TERMINAL_ID=CP3 CLAUDE_PROJECT_DIR="$proj3" \
    BATON_DIR="$tracking3" \
    bash "$SS" <<<'{"session_id":"sid-cp3","cwd":"'"$proj3"'"}' 2>&1)
  assert "CRON-PROBE: stale warning reports hours past default grace" \
    "echo \"\$out3\" | grep -qE 'last swept [0-9]+h ago'"
  rm -rf "$proj3"

  # Case 4: marker ~95h old (default grace 96h - 1) → silent (within grace)
  local proj4; proj4=$(mkv2); local tracking4="$proj4/docs/sessions/.tracking"
  touch -d "@$(( $(date -u +%s) - 95*3600 ))" "$tracking4/.cron-last-run"
  local out4
  out4=$(USER=u CLAUDE_TERMINAL_ID=CP4 CLAUDE_PROJECT_DIR="$proj4" \
    BATON_DIR="$tracking4" \
    bash "$SS" <<<'{"session_id":"sid-cp4","cwd":"'"$proj4"'"}' 2>&1)
  assert "CRON-PROBE: silent just under default grace" \
    "! echo \"\$out4\" | grep -q 'last swept'"
  rm -rf "$proj4"

  # Case 5: same ~50h marker, but BATON_SWEEP_INTERVAL_HOURS=24 (grace 48h)
  #   → now stale (50 > 48) though silent under the default 96h grace.
  local proj5; proj5=$(mkv2); local tracking5="$proj5/docs/sessions/.tracking"
  touch -d "@$(( $(date -u +%s) - 50*3600 ))" "$tracking5/.cron-last-run"
  local out5
  out5=$(USER=u CLAUDE_TERMINAL_ID=CP5 CLAUDE_PROJECT_DIR="$proj5" \
    BATON_SWEEP_INTERVAL_HOURS=24 BATON_DIR="$tracking5" \
    bash "$SS" <<<'{"session_id":"sid-cp5","cwd":"'"$proj5"'"}' 2>&1)
  assert "CRON-PROBE: configurable interval flips verdict at same age" \
    "echo \"\$out5\" | grep -qE 'last swept [0-9]+h ago'"
  rm -rf "$proj5"
}
run_cron_probe_warning

# E1: checkpoint stamps session_id on workstreams/<ws>.json (update-existing branch)
run_e1_ckpt_stamp() {
  local proj; proj=$(mkproj)
  mkdir -p "$proj/docs/sessions/.tracking/workstreams" "$proj/docs/sessions/.tracking/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  local sid="sid-e1ck-$$"
  local t_file="$proj/docs/sessions/.tracking/e1ck-t.json"
  echo '{"workstream":"ws-e1ck","display_name":"alpha","phase":"impl"}' > "$t_file"
  echo "$t_file" > "/tmp/claude-session-tracking-$sid"
  seed_terminal "$proj/docs/sessions/.tracking" "E1CkTerm" "ws-e1ck" "alpha"
  touch "/tmp/baton-pending-$sid"
  local f="$proj/docs/sessions/progress-ws-e1ck-1.md"
  echo "# saved" > "$f"
  run_checkpoint "$proj" "$sid" "$alpha" "$f" E1CkTerm >/dev/null 2>&1
  local got; got=$(jq -r '.session_id // empty' "$proj/docs/sessions/.tracking/workstreams/ws-e1ck.json" 2>/dev/null)
  assert "E1: checkpoint stamps session_id on workstream record" "[ '$got' = '$sid' ]"
  rm -f "/tmp/claude-session-tracking-$sid" "/tmp/baton-pending-$sid" "/tmp/baton-done-$sid"
  rm -rf "$proj"
}
run_e1_ckpt_stamp

# ===== E1 crash-recovery: session-start reacquisition (design D, 3 required tests) =====

# E1-A: /clear in a bound terminal resolves via terminal_hash and NEVER via session_id.
# A decoy workstream carries the CURRENT session_id; the terminal is bound to a DIFFERENT ws.
# Correct behavior: terminal wins -> bound ws, decoy ignored.
run_e1_clear_terminal_precedence() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local sid="sid-e1clear-$$"
  # bound ws (terminal points here)
  jq -n '{workstream:"ws-bound", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z", session_id:"old-sid"}' > "$tr/workstreams/ws-bound.json"
  seed_terminal "$tr" "ClearTerm" "ws-bound" "alpha"
  # decoy ws whose session_id == the NEW /clear session id
  jq -n --arg sid "$sid" '{workstream:"ws-decoy", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T09:00:00Z", session_id:$sid}' > "$tr/workstreams/ws-decoy.json"
  USER=u CLAUDE_TERMINAL_ID=ClearTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$alpha\",\"source\":\"clear\"}" >/dev/null 2>&1
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=ClearTerm term_hash)
  local bound; bound=$(jq -r '.workstream' "$tr/terminals/${th}.json")
  assert "E1-A: /clear resolves via terminal_hash (ws-bound, not decoy)" "[ '$bound' = 'ws-bound' ]"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_e1_clear_terminal_precedence

# E1-B: new terminal + resumed session_id reacquires W and rebinds the new terminal onto it.
run_e1_reacquire() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local sid="sid-e1re-$$"
  # W carries the resumed session_id; NO terminal binding exists for NewTerm.
  jq -n --arg sid "$sid" '{workstream:"ws-W", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z", session_id:$sid}' > "$tr/workstreams/ws-W.json"
  USER=u CLAUDE_TERMINAL_ID=NewTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$alpha\",\"source\":\"resume\"}" >/dev/null 2>&1
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=NewTerm term_hash)
  assert "E1-B: new terminal rebound onto reacquired W" "[ -f '$tr/terminals/${th}.json' ] && [ \"\$(jq -r .workstream '$tr/terminals/${th}.json')\" = 'ws-W' ]"
  # And no blank fork workstream was minted (only ws-W exists).
  local n; n=$(ls "$tr/workstreams"/*.json | wc -l)
  assert "E1-B: no fork workstream minted (count=1)" "[ '$n' -eq 1 ]"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_e1_reacquire

# E1-C: new terminal + fresh session_id (no matching record) -> fresh mint.
run_e1_fresh_mint() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  # An unrelated ws with a DIFFERENT session_id exists; must NOT be reacquired.
  jq -n '{workstream:"ws-other", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z", session_id:"unrelated-sid"}' > "$tr/workstreams/ws-other.json"
  local sid="sid-e1fresh-$$"
  USER=u CLAUDE_TERMINAL_ID=FreshTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$alpha\",\"source\":\"resume\"}" >/dev/null 2>&1
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=FreshTerm term_hash)
  local bound; bound=$(jq -r '.workstream' "$tr/terminals/${th}.json" 2>/dev/null)
  assert "E1-C: fresh session_id mints a NEW workstream (not ws-other)" "[ -n '$bound' ] && [ '$bound' != 'ws-other' ]"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_e1_fresh_mint

# E1-D: SessionStart stamps session_id on the bound (existing) workstream record.
run_e1_ss_stamp() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  jq -n '{workstream:"ws-stamp", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z"}' > "$tr/workstreams/ws-stamp.json"
  seed_terminal "$tr" "StampTerm" "ws-stamp" "alpha"
  local sid="sid-e1stamp-$$"
  USER=u CLAUDE_TERMINAL_ID=StampTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$alpha\",\"source\":\"startup\"}" >/dev/null 2>&1
  local got; got=$(jq -r '.session_id // empty' "$tr/workstreams/ws-stamp.json")
  assert "E1-D: SessionStart stamps session_id on bound record" "[ '$got' = '$sid' ]"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_e1_ss_stamp

# E1-E: STALE terminal HIT + resumed session_id. term_hash collides with a prior
# workstream's terminals/<hash>.json (reused tty after reboot), so the terminal
# HIT binds the resumed session to the WRONG (stale) ws-A. The live session_id is
# authoritatively stamped on ws-B; a resume must divert to ws-B and REBIND the
# stale terminal. This is the seam-#1 fix: the terminal-MISS reacquire never fires
# here because the (stale) terminal record exists.
run_e1_stale_terminal_rebind() {
  local proj; proj=$(mkproj)
  local tr="$proj/docs/sessions/.tracking"
  mkdir -p "$tr/workstreams" "$tr/terminals"
  local alpha; alpha=$(mkproject_link "$proj" "alpha")
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local sid="sid-e1stale-$$"
  # Stale terminal HIT: CollTerm hashes to H, terminals/H.json -> ws-A.
  jq -n '{workstream:"ws-A", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-10T00:00:00Z", session_id:"stale-sid"}' > "$tr/workstreams/ws-A.json"
  seed_terminal "$tr" "CollTerm" "ws-A" "alpha"
  # ws-B authoritatively carries the LIVE resumed session_id.
  jq -n --arg sid "$sid" '{workstream:"ws-B", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z", session_id:$sid}' > "$tr/workstreams/ws-B.json"
  USER=u CLAUDE_TERMINAL_ID=CollTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$alpha\",\"source\":\"resume\"}" >/dev/null 2>&1
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=CollTerm term_hash)
  local bound; bound=$(jq -r '.workstream' "$tr/terminals/${th}.json" 2>/dev/null)
  assert "E1-E: stale terminal HIT diverts + rebinds onto ws-B" "[ '$bound' = 'ws-B' ]"
  assert "E1-E: rebind-stale-terminal event logged" "jq -e 'select(.event==\"rebind-stale-terminal\" and .to==\"ws-B\")' '$tr/hook-events.jsonl' >/dev/null 2>&1"
  rm -f "/tmp/claude-session-tracking-$sid"; rm -rf "$proj"
}
run_e1_stale_terminal_rebind

# E1-F: a DELIBERATE project switch (project-detect rebind) must SURVIVE the next
# non-clear SessionStart. The switch rebinds the terminal AND moves the session_id
# stamp onto the target; without the stamp-move the terminal-HIT cross-check (E1-E)
# would find the live session_id still on the pre-switch ws and revert the switch.
# Regression for the session_id stamp added to project-detect.sh's rebind branch.
run_e1_switch_survives_ss() {
  local proj; proj=$(mkv2)
  local tr="$proj/docs/sessions/.tracking"
  source "$HOOKS_DIR/lib/workstream-lib.sh"
  local sid="sid-e1switch-$$"
  # Bound pre-switch ws "cur" carries the live session_id; "ckpt" is the switch target.
  jq -n --arg sid "$sid" '{workstream:"cur", display_name:"alpha", progress_file:"", phase:"impl", updated_at:"2026-07-11T00:00:00Z", session_id:$sid}' > "$tr/workstreams/cur.json"
  jq -n '{workstream:"ckpt", display_name:"baton", progress_file:"", phase:"impl", updated_at:"2026-07-10T00:00:00Z"}' > "$tr/workstreams/ckpt.json"
  local th; th=$(USER=u CLAUDE_TERMINAL_ID=SwTerm term_hash)
  jq -n '{terminal_id:"SwTerm", workstream:"cur", updated_at:"2026-07-11T00:00:00Z"}' > "$tr/terminals/${th}.json"
  jq -n --arg sid "$sid" '{session_id:$sid, workstream:"cur"}' > "$tr/sess.json"
  echo "$tr/sess.json" > "/tmp/claude-session-tracking-${sid}"
  mkdir -p "$proj/proj-baton"; ln -s "$proj/proj-baton" "$proj/projects/baton"
  # 1) deliberate switch to baton -> project-detect rebinds terminal to ckpt
  USER=u CLAUDE_TERMINAL_ID=SwTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$HOOKS_DIR/project-detect.sh" \
    <<<"{\"session_id\":\"$sid\",\"prompt\":\"let us work on baton now\",\"cwd\":\"$proj\"}" >/dev/null 2>&1
  # 2) next SessionStart (compact = non-clear) must NOT revert the switch
  USER=u CLAUDE_TERMINAL_ID=SwTerm CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<"{\"session_id\":\"$sid\",\"cwd\":\"$proj\",\"source\":\"compact\"}" >/dev/null 2>&1
  local bound; bound=$(jq -r '.workstream' "$tr/terminals/${th}.json" 2>/dev/null)
  assert "E1-F: deliberate switch survives next SessionStart (stays ckpt)" "[ '$bound' = 'ckpt' ]"
  rm -f "/tmp/claude-session-tracking-${sid}"; rm -rf "$proj"
}
run_e1_switch_survives_ss

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
