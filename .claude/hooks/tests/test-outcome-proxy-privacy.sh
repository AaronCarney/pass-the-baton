#!/usr/bin/env bash
# test-outcome-proxy-privacy.sh - sentinel-grep privacy gate (T7b)
# Injects 4 sentinel strings into all proxy input paths; asserts NONE appear
# in outcome_proxy event payloads in the resulting hook-events.jsonl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/outcome-proxies"

T2_HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-code-execution.sh"
T3_HOOK="$REPO_ROOT/.claude/hooks/outcome-proxy-retry-density.sh"
FOLLOW_UP="$REPO_ROOT/tools/outcome-proxy-follow-up.sh"
COMMIT_SURVIVAL="$REPO_ROOT/tools/outcome-proxy-commit-survival.sh"

TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so the privacy assertions test the
# sentinel-grep path (with consent ON), not the new collection gate.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT

PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi
}

# Consent ON
export BATON_OUTCOME_PROXIES=1

# ── Sentinel strings ───────────────────────────────────────────────────────
S1="SENTINEL_PROMPT_TOKEN_xyz123"
S2="SENTINEL_TEST_OUTPUT_abc456"
S3="SENTINEL_COMMAND_BODY_qrs789"
S4="SENTINEL_PROJECT_SLUG_def012"

# ── Seed a project_boundary event with S4 in the slug ─────────────────────
# (allowed structurally - assertion only checks outcome_proxy payloads)
printf '{"schema_version":1,"event":"project_boundary","ts":"2026-05-25T00:00:00Z","data":{"kind":"start","slug":"%s","workstream":"main","terminal_id":"term-priv","session_id":"sess-priv-sentinel"}}\n' \
  "$S4" >> "$BATON_EVENT_LOG"

# ── Invoke hooks from sentinel-corpus.jsonl ────────────────────────────────
CORPUS="$FIXTURE_DIR/sentinel-corpus.jsonl"

# Line 1: code_execution hook with command body + stdout containing sentinels
CE_STDIN=$(jq -r 'select(.hook=="code_execution") | .stdin | tojson' "$CORPUS")
printf '%s\n' "$CE_STDIN" | bash "$T2_HOOK" 2>/dev/null || true

# Line 2: retry_density hook with prompt containing S1
RD_STDIN=$(jq -r 'select(.hook=="retry_density") | .stdin | tojson' "$CORPUS")
printf '%s\n' "$RD_STDIN" | bash "$T3_HOOK" 2>/dev/null || true

# ── T4a: follow-up tool (slug = S4, from project_boundary) ────────────────
TMP_TRANS="$TMP_STATE/transcripts"
mkdir -p "$TMP_TRANS/main"
printf '{"type":"assistant","message":"hi"}\n' > "$TMP_TRANS/main/sess-priv-sentinel.jsonl"

bash "$FOLLOW_UP" --transcripts-dir "$TMP_TRANS" 2>/dev/null || true

# ── T4b: commit-survival tool (slug argument = S4) ────────────────────────
TMP_GIT="$TMP_STATE/git-repo"
mkdir -p "$TMP_GIT"
git -C "$TMP_GIT" init -q
git -C "$TMP_GIT" config user.email "test@test.com"
git -C "$TMP_GIT" config user.name "Test"
printf 'hello\n' > "$TMP_GIT/file.txt"
git -C "$TMP_GIT" add file.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
  git -C "$TMP_GIT" commit -q -m "init"

bash "$COMMIT_SURVIVAL" --repo "$TMP_GIT" --slug "$S4" 2>/dev/null || true

# ── Extract outcome_proxy payloads only ───────────────────────────────────
OP_PAYLOADS=$(jq -r 'select(.event == "outcome_proxy") | .data | tojson' \
  "$BATON_EVENT_LOG" 2>/dev/null || true)

# ── Assert: no sentinel in outcome_proxy payloads ─────────────────────────
# S1-S3: must not appear in ANY outcome_proxy payload
for sentinel in "$S1" "$S2" "$S3"; do
  count=$(printf '%s' "$OP_PAYLOADS" | grep -F "$sentinel" 2>/dev/null | wc -l | tr -d ' ')
  assert "sentinel '$sentinel' absent from outcome_proxy payloads" "[ \"$count\" -eq 0 ]"
done

# S4 (project slug): slug is a structural identifier carried by follow_up events by design
# (analogous to project_boundary carrying slug through). Assert it is absent from non-follow_up
# outcome_proxy payloads (code_execution, retry, commit_survival) - the privacy-critical paths.
OP_NON_FOLLOW=$(jq -r 'select(.event == "outcome_proxy" and .data.subkind != "follow_up") | .data | tojson' \
  "$BATON_EVENT_LOG" 2>/dev/null || true)
count_s4=$(printf '%s' "$OP_NON_FOLLOW" | grep -F "$S4" 2>/dev/null | wc -l | tr -d ' ')
assert "sentinel '$S4' absent from non-follow_up outcome_proxy payloads" "[ \"$count_s4\" -eq 0 ]"

# Sanity: some outcome_proxy events were actually emitted (consent is ON)
n_proxy=$(printf '%s' "$OP_PAYLOADS" | grep -c '"subkind"' 2>/dev/null | tr -d ' ' || echo 0)
assert 'privacy: at least 1 outcome_proxy event emitted (consent is on)' "[ \"$n_proxy\" -ge 1 ]"

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
