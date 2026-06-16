#!/usr/bin/env bash
# test-outcome-proxy-consent.sh - consent-off integration test (T7a)
# All 4 proxy paths invoked; BATON_OUTCOME_PROXIES unset → zero outcome_proxy events.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

T2_HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-code-execution.sh"
T3_HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-retry-density.sh"
FOLLOW_UP="$REPO_ROOT/tools/outcome-proxy-follow-up.sh"
COMMIT_SURVIVAL="$REPO_ROOT/tools/outcome-proxy-commit-survival.sh"

TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so the thing under test is the
# OUTCOME-PROXY CONSENT gate (BATON_OUTCOME_PROXIES), not the collection gate.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT

PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi
}

# Consent OFF - must be unset (not just =0) to cover both branches
unset BATON_OUTCOME_PROXIES

# ── Seed 1 project_boundary event (this is allowed to appear) ─────────────
printf '{"schema_version":1,"event":"project_boundary","ts":"2026-05-25T00:00:00Z","data":{"kind":"start","slug":"slug-consent-test","workstream":"main","terminal_id":"term-t7","session_id":"sess-consent-test"}}\n' \
  >> "$BATON_EVENT_LOG"

# ── T2: code-execution hook with valid pytest stdin ────────────────────────
printf '{"tool_name":"Bash","tool_input":{"command":"pytest tests/"},"tool_response":{"exit_code":0,"stdout":"1 passed"}}\n' \
  | bash "$T2_HOOK" 2>/dev/null || true

# ── T3: retry-density hook with valid prompt+session_id stdin ─────────────
printf '{"prompt":"please fix the failing test","session_id":"sess-consent-test"}\n' \
  | bash "$T3_HOOK" 2>/dev/null || true

# ── T4a: follow-up tool (needs project_boundary in log) ───────────────────
# Build a minimal transcript dir so the tool can find sessions
TMP_TRANS="$TMP_STATE/transcripts"
mkdir -p "$TMP_TRANS/main"
printf '{"type":"assistant","message":"hi"}\n' > "$TMP_TRANS/main/sess-consent-test.jsonl"

bash "$FOLLOW_UP" --transcripts-dir "$TMP_TRANS" 2>/dev/null || true

# ── T4b: commit-survival tool on a temp git repo ──────────────────────────
TMP_GIT="$TMP_STATE/git-repo"
mkdir -p "$TMP_GIT"
git -C "$TMP_GIT" init -q
git -C "$TMP_GIT" config user.email "test@test.com"
git -C "$TMP_GIT" config user.name "Test"
printf 'hello\n' > "$TMP_GIT/file.txt"
git -C "$TMP_GIT" add file.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
  git -C "$TMP_GIT" commit -q -m "init"

bash "$COMMIT_SURVIVAL" --repo "$TMP_GIT" --slug "consent-test-repo" 2>/dev/null || true

# ── Assert: zero outcome_proxy events in the log ─────────────────────────
n_outcome_proxy=0
if [ -f "$BATON_EVENT_LOG" ]; then
  n_outcome_proxy=$(grep '"outcome_proxy"' "$BATON_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
fi

assert 'consent-off: zero outcome_proxy events after all 4 proxy invocations' \
  "[ \"$n_outcome_proxy\" -eq 0 ]"

# Sanity: the event log may not exist, or if it does, the seed project_boundary is OK
if [ -f "$BATON_EVENT_LOG" ]; then
  n_seed=$(grep '"project_boundary"' "$BATON_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
  assert 'consent-off: seed project_boundary event present (sanity)' "[ \"$n_seed\" -ge 1 ]"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
