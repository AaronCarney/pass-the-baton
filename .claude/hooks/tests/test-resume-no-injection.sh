#!/usr/bin/env bash
# `claude --resume` reloads the full prior transcript, so the progress file is
# already in context. Re-injecting it there is not a no-op: it re-asserts a
# possibly-stale assignment ON TOP of a transcript that shows newer work, and
# the directive text ("this IS your assignment, do NOT re-scope") makes the
# stale copy win. startup/clear/compact all begin with the transcript gone or
# summarized, so for those the progress file is the only bridge and must inject.
#
# Contract: source=resume still resolves + binds the terminal, but emits no
# progress injection.
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SS="$HOOKS_DIR/session-start.sh"
source "$HOOKS_DIR/lib/workstream-lib.sh"

PASS=0; FAIL=0; FAILED=()
assert(){ if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); fi; }

mkp(){ local d; d=$(mktemp -d); mkdir -p "$d/docs/sessions/.tracking/"{terminals,workstreams}; echo "$d"; }

# Seed a workstream whose progress file EXISTS, bound to terminal ME.
seed(){
  local proj="$1" tr="$2" now prog me
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  prog="$proj/progress-bound.md"
  printf '## What is Next\nSENTINEL_PROGRESS_BODY\n' > "$prog"
  jq -n --arg p "$prog" --arg ts "$now" --arg pd "$proj" \
    '{workstream:"bound",display_name:"bound",progress_file:$p,phase:"implementation",updated_at:$ts,project_dir:$pd,session_id:"me-sid"}' \
    > "$tr/workstreams/bound.json"
  me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
  jq -n --arg ts "$now" '{terminal_id:"ME",workstream:"bound",updated_at:$ts}' > "$tr/terminals/${me}.json"
}

run_source(){ # $1=proj $2=tracking $3=source -> stdout of the hook
  local proj="$1" tr="$2" src="$3"
  USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
    bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'","source":"'"$src"'"}' 2>&1
}

echo "## session-start.sh: resume must not re-inject progress"

# A: resume -> NO injection
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed "$proj" "$tr"
out=$(run_source "$proj" "$tr" resume)
assert "A-resume-no-injection-header" '! echo "$out" | grep -q "Workstream Progress (auto-injected)"'
assert "A-resume-no-progress-body"    '! echo "$out" | grep -q "SENTINEL_PROGRESS_BODY"'
assert "A-resume-no-assignment-text"  '! echo "$out" | grep -q "IS your assignment"'
rm -rf "$proj"

# B: resume STILL binds the terminal (the part that must keep working)
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed "$proj" "$tr"
run_source "$proj" "$tr" resume >/dev/null 2>&1
me=$(USER=u CLAUDE_TERMINAL_ID=ME term_hash)
assert "B-resume-still-binds" "[ \"\$(jq -r .workstream \"$tr/terminals/${me}.json\")\" = bound ]"
rm -rf "$proj"

# C/D/E: the transcript-less sources MUST still inject
for src in startup clear compact; do
  proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed "$proj" "$tr"
  out=$(run_source "$proj" "$tr" "$src")
  assert "C-${src}-still-injects-header" 'echo "$out" | grep -q "Workstream Progress (auto-injected)"'
  assert "C-${src}-still-injects-body"   'echo "$out" | grep -q "SENTINEL_PROGRESS_BODY"'
  rm -rf "$proj"
done

# F: unknown source (no .source key) keeps injecting - fail safe, not silent
proj=$(mkp); tr="$proj/docs/sessions/.tracking"; seed "$proj" "$tr"
out=$(USER=u CLAUDE_TERMINAL_ID=ME CLAUDE_PROJECT_DIR="$proj" BATON_DIR="$tr" \
  bash "$SS" <<<'{"session_id":"me-sid","cwd":"'"$proj"'"}' 2>&1)
assert "F-unknown-source-still-injects" 'echo "$out" | grep -q "Workstream Progress (auto-injected)"'
rm -rf "$proj"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'failed: %s\n' "${FAILED[@]}"; exit 1; }
