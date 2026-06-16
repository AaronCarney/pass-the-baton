#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FOLLOW_UP="$REPO_ROOT/tools/outcome-proxy-follow-up.sh"
COMMIT_SURVIVAL="$REPO_ROOT/tools/outcome-proxy-commit-survival.sh"
TMP_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TMP_STATE"
export BATON_EVENT_LOG="$TMP_STATE/hook-events.jsonl"
# E23 off-by-default: open the collection gate so emit-and-assert paths collect.
export BATON_COLLECT=1
trap 'rm -rf "$TMP_STATE"' EXIT
PASS=0; FAIL=0
assert() { local label="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $label" >&2; fi; }

assert 'follow-up tool is executable' "[ -x \"$FOLLOW_UP\" ]"
assert 'commit-survival tool is executable' "[ -x \"$COMMIT_SURVIVAL\" ]"

# === helper: build ephemeral git fixture ===
make_git_fixture() {
  local d
  d=$(mktemp -d "$TMP_STATE/git-fixture-XXXXXX")
  # Use a recent date so --since="365 days ago" window includes them.
  local fixed_date="2025-12-01T00:00:00Z"
  export GIT_AUTHOR_DATE="$fixed_date"
  export GIT_COMMITTER_DATE="$fixed_date"
  export GIT_AUTHOR_NAME="Test"
  export GIT_AUTHOR_EMAIL="test@test.com"
  export GIT_COMMITTER_NAME="Test"
  export GIT_COMMITTER_EMAIL="test@test.com"
  git -C "$d" init -q
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  # 4 original commits
  for i in 1 2 3 4; do
    echo "file$i" > "$d/file$i.txt"
    git -C "$d" add "file$i.txt"
    git -C "$d" commit -q -m "commit-$i"
  done
  # Revert commit-1 (HEAD~3 from 4 commits = first commit)
  # The revert subject will be 'Revert "commit-1"', giving 5 total subjects.
  git -C "$d" revert --no-edit HEAD~3 >/dev/null 2>&1
  echo "$d"
}
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# === F8+F9: follow-up tool test ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"

# Build transcript fixtures: ws-foo with 2 sessions (5 lines each), ws-bar with 1 session (3 lines)
TMP_TRANSCRIPTS="$TMP_STATE/transcripts"
mkdir -p "$TMP_TRANSCRIPTS/ws-foo" "$TMP_TRANSCRIPTS/ws-bar"
for i in 1 2 3 4 5; do
  echo '{"type":"assistant","message":"hi"}' >> "$TMP_TRANSCRIPTS/ws-foo/sess-a.jsonl"
  echo '{"type":"assistant","message":"hi"}' >> "$TMP_TRANSCRIPTS/ws-foo/sess-b.jsonl"
done
for i in 1 2 3; do
  echo '{"type":"assistant","message":"hi"}' >> "$TMP_TRANSCRIPTS/ws-bar/sess-c.jsonl"
done

# Seed event log with 3 project_boundary start events
cat >> "$BATON_EVENT_LOG" <<'JSONEOF'
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:00:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-1"}}
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:01:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-2"}}
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:02:00Z","data":{"kind":"start","slug":"bar","workstream":"ws-bar","terminal_id":"term-3"}}
JSONEOF

bash "$FOLLOW_UP" --transcripts-dir "$TMP_TRANSCRIPTS"

n_events=$(wc -l < "$BATON_EVENT_LOG" | awk '{print $1}')
# Subtract the 3 seeded events: should have 2 outcome_proxy events
n_proxy=$(jq -s '[.[] | select(.event=="outcome_proxy")] | length' "$BATON_EVENT_LOG")
assert 'F9: 2 outcome_proxy events emitted (one per slug)' "[ \"$n_proxy\" -eq 2 ]"

foo_ev=$(jq -s '[.[] | select(.event=="outcome_proxy" and .data.slug=="foo")] | .[0].data' "$BATON_EVENT_LOG")
bar_ev=$(jq -s '[.[] | select(.event=="outcome_proxy" and .data.slug=="bar")] | .[0].data' "$BATON_EVENT_LOG")

assert 'F9: foo n_sessions=2' "echo '$foo_ev' | jq -e '.n_sessions == 2' >/dev/null"
assert 'F9: foo n_terminals=2' "echo '$foo_ev' | jq -e '.n_terminals == 2' >/dev/null"
assert 'F8: foo total_turns=10' "echo '$foo_ev' | jq -e '.total_turns == 10' >/dev/null"
assert 'F8: foo mean_turns_per_session=5.00' "echo '$foo_ev' | jq -e '.mean_turns_per_session == 5' >/dev/null"
assert 'F9: bar n_sessions=1' "echo '$bar_ev' | jq -e '.n_sessions == 1' >/dev/null"
assert 'F9: bar n_terminals=1' "echo '$bar_ev' | jq -e '.n_terminals == 1' >/dev/null"
assert 'F8: bar total_turns=3' "echo '$bar_ev' | jq -e '.total_turns == 3' >/dev/null"
assert 'F8: bar mean_turns_per_session=3.00' "echo '$bar_ev' | jq -e '.mean_turns_per_session == 3' >/dev/null"

# F8 negative: no --transcripts-dir, missing default → stderr warning, mean_turns=0
rm -f "$BATON_EVENT_LOG"
cat >> "$BATON_EVENT_LOG" <<'JSONEOF'
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:00:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-1"}}
JSONEOF
BOGUS_HOME="$TMP_STATE/nonexistent"
stderr_out=$(BATON_CORPUS_DIR="" HOME="$BOGUS_HOME" bash "$FOLLOW_UP" 2>&1 1>/dev/null)
assert 'F8 negative: stderr contains warning' "echo \"$stderr_out\" | grep -q 'transcripts directory not found'"
# re-run capturing actual emitted event
rm -f "$BATON_EVENT_LOG"
cat >> "$BATON_EVENT_LOG" <<'JSONEOF'
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:00:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-1"}}
JSONEOF
BATON_CORPUS_DIR="" HOME="$BOGUS_HOME" bash "$FOLLOW_UP" 2>/dev/null
foo_neg=$(jq -s '[.[] | select(.event=="outcome_proxy" and .data.slug=="foo")] | .[0].data' "$BATON_EVENT_LOG")
assert 'F8 negative: mean_turns_per_session=0 on missing transcripts dir' "echo '$foo_neg' | jq -e '.mean_turns_per_session == 0' >/dev/null"

# === CC20: malformed-line (NUL) tolerance for the pairs read (37-45) ===
# Inject a NUL so a project_boundary 'start' record FOLLOWS it; the post-NUL
# slug must still appear in `pairs` (covers outcome-proxy-follow-up.sh:37-45).
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"
{
  printf '%s\n' '{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:00:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-1"}}'
  printf '\0\0\0\n'
  printf '%s\n' '{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:03:00Z","data":{"kind":"start","slug":"postnul","workstream":"ws-bar","terminal_id":"term-9"}}'
} > "$BATON_EVENT_LOG"
nul_json=$(bash "$FOLLOW_UP" --transcripts-dir "$TMP_TRANSCRIPTS" --json 2>/dev/null)
assert 'NUL: post-NUL slug present in pairs read (follow-up :37-45)' \
  "printf '%s' \"\$nul_json\" | jq -se 'any(.[]; .slug == \"postnul\")' >/dev/null"
unset BATON_OUTCOME_PROXIES

# === Commit-survival test ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"

FIXTURE=$(make_git_fixture)

out=$(bash "$COMMIT_SURVIVAL" --repo "$FIXTURE" --window-days 365 --slug fix-foo --json)
assert 'commit-survival: n_commits=5' "echo '$out' | jq -e '.n_commits == 5' >/dev/null"
assert 'commit-survival: n_survived=4' "echo '$out' | jq -e '.n_survived == 4' >/dev/null"
assert 'commit-survival: n_reverted=1' "echo '$out' | jq -e '.n_reverted == 1' >/dev/null"
assert 'commit-survival: survival_fraction=0.8' "echo '$out' | jq -e '.survival_fraction == 0.8' >/dev/null"

# Empty-window shape: must match populated-window field names (no n_reverts drift).
# Use an empty git repo (no commits) so the --since filter is irrelevant.
EMPTY_GIT=$(mktemp -d)
( cd "$EMPTY_GIT" && git init -q )
empty_out=$(bash "$COMMIT_SURVIVAL" --repo "$EMPTY_GIT" --window-days 1 --slug empty-foo --json)
assert 'commit-survival empty-window: n_commits=0' "echo '$empty_out' | jq -e '.n_commits == 0' >/dev/null"
assert 'commit-survival empty-window: emits n_reverted (not n_reverts) - schema consistency with populated branch' "echo '$empty_out' | jq -e 'has(\"n_reverted\") and (has(\"n_reverts\") | not)' >/dev/null"
rm -rf "$EMPTY_GIT"
assert 'privacy: no commit_sha field' "echo '$out' | jq -e 'has(\"commit_sha\") | not' >/dev/null"
assert 'privacy: no message field' "echo '$out' | jq -e 'has(\"message\") | not' >/dev/null"
assert 'privacy: no author field' "echo '$out' | jq -e 'has(\"author\") | not' >/dev/null"
assert 'privacy: no paths field' "echo '$out' | jq -e 'has(\"paths\") | not' >/dev/null"

unset BATON_OUTCOME_PROXIES

# === Consent-off test: both tools emit 0 events without --json ===
unset BATON_OUTCOME_PROXIES
rm -f "$BATON_EVENT_LOG"
cat >> "$BATON_EVENT_LOG" <<'JSONEOF'
{"schema_version":1,"event":"project_boundary","ts":"2024-01-01T00:00:00Z","data":{"kind":"start","slug":"foo","workstream":"ws-foo","terminal_id":"term-1"}}
JSONEOF
# Run follow-up (no --json, no consent)
bash "$FOLLOW_UP" --transcripts-dir "$TMP_TRANSCRIPTS" 2>/dev/null || true
n_proxy_after_follow=$(jq -s '[.[] | select(.event=="outcome_proxy")] | length' "$BATON_EVENT_LOG")
assert 'consent off: follow-up emits 0 outcome_proxy events' "[ \"$n_proxy_after_follow\" -eq 0 ]"
# Run commit-survival (no --json, no consent)
bash "$COMMIT_SURVIVAL" --repo "$FIXTURE" --window-days 365 --slug fix-foo 2>/dev/null || true
n_proxy_after_survival=$(jq -s '[.[] | select(.event=="outcome_proxy")] | length' "$BATON_EVENT_LOG")
assert 'consent off: commit-survival emits 0 outcome_proxy events' "[ \"$n_proxy_after_survival\" -eq 0 ]"

# === slug presence in async-tool events ===
export BATON_OUTCOME_PROXIES=1
rm -f "$BATON_EVENT_LOG"

# Seed a project_boundary event + projects state file so follow-up has data to walk.
mkdir -p "$TMP_STATE/baton/projects"
echo '{"slug":"slug-fu-x","started_at":"2026-05-26T00:00:00Z","workstream":"main","description":"","notes":[]}' > "$TMP_STATE/baton/projects/slug-fu-x.json"
# Emit a project_boundary so the follow-up tool sees the slug as active.
printf '%s\n' '{"ts":"2026-05-26T00:00:00Z","schema_version":1,"event":"project_boundary","data":{"slug":"slug-fu-x","kind":"start","workstream":"main","terminal_id":"term-fu"}}' > "$BATON_EVENT_LOG"

bash "$REPO_ROOT/tools/outcome-proxy-follow-up.sh" >/dev/null 2>&1 || true
FU_EVT_FILE="$TMP_STATE/fu-evt.json"
grep '"subkind":"follow_up"' "$BATON_EVENT_LOG" | tail -1 > "$FU_EVT_FILE"
assert 'follow-up event emitted' "[ -s \"$FU_EVT_FILE\" ]"
assert 'follow-up event carries slug field' "jq -e '.data.slug == \"slug-fu-x\"' \"$FU_EVT_FILE\" >/dev/null"

# Same for commit-survival on an isolated tmp git repo.
TMP_GIT=$(mktemp -d)
( cd "$TMP_GIT" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -m 'seed' -q )
rm -f "$BATON_EVENT_LOG"
printf '%s\n' '{"ts":"2026-05-26T00:00:00Z","schema_version":1,"event":"project_boundary","data":{"slug":"slug-cs-y","kind":"start","workstream":"main","terminal_id":"term-cs"}}' > "$BATON_EVENT_LOG"
bash "$REPO_ROOT/tools/outcome-proxy-commit-survival.sh" --repo "$TMP_GIT" --slug slug-cs-y --window-days 14 >/dev/null 2>&1 || true
CS_EVT_FILE="$TMP_STATE/cs-evt.json"
grep '"subkind":"commit_survival"' "$BATON_EVENT_LOG" | tail -1 > "$CS_EVT_FILE"
assert 'commit-survival event emitted' "[ -s \"$CS_EVT_FILE\" ]"
assert 'commit-survival event carries slug field' "jq -e '.data.slug == \"slug-cs-y\"' \"$CS_EVT_FILE\" >/dev/null"

# Backward-compat sibling-field presence (closeout iter-2): adding `slug` MUST NOT remove pre-existing fields.
# Values are tool-computed from the fixture (only 1 seeded session/commit), so this asserts presence + non-null only.
assert 'follow_up backward-compat: n_sessions field present + non-null' "jq -e '.data.n_sessions != null' \"$FU_EVT_FILE\" >/dev/null"
assert 'follow_up backward-compat: mean_turns_per_session field present + non-null' "jq -e '.data.mean_turns_per_session != null' \"$FU_EVT_FILE\" >/dev/null"
assert 'follow_up backward-compat: total_turns field present + non-null' "jq -e '.data.total_turns != null' \"$FU_EVT_FILE\" >/dev/null"
assert 'follow_up backward-compat: n_terminals field present + non-null (closeout iter-4)' "jq -e '.data.n_terminals != null' \"$FU_EVT_FILE\" >/dev/null"
assert 'commit_survival backward-compat: n_commits field present + non-null' "jq -e '.data.n_commits != null' \"$CS_EVT_FILE\" >/dev/null"
assert 'commit_survival backward-compat: n_survived field present + non-null' "jq -e '.data.n_survived != null' \"$CS_EVT_FILE\" >/dev/null"
assert 'commit_survival backward-compat: survival_fraction field present + non-null' "jq -e '.data.survival_fraction != null' \"$CS_EVT_FILE\" >/dev/null"
assert 'commit_survival backward-compat: window_days field present + non-null (closeout iter-4)' "jq -e '.data.window_days != null' \"$CS_EVT_FILE\" >/dev/null"
assert 'commit_survival backward-compat: n_reverted field present + non-null (closeout iter-4)' "jq -e '.data.n_reverted != null' \"$CS_EVT_FILE\" >/dev/null"

rm -rf "$TMP_GIT"
unset BATON_OUTCOME_PROXIES

echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
