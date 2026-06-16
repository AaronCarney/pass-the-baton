#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label" >&2; fi
}

# ---- Step 1: arg parsing - missing --events → rc=1 ----
rc=0; out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" 2>&1) || rc=$?
assert 'no args → rc=1' "[ $rc -eq 1 ]"
assert 'no args mentions --events' "printf '%s' \"\$out\" | grep -q -- '--events'"

# ---- Step 4: happy path - single closed project, JSON output, per-session attribution ----
EVENTS=$(mktemp)
cat > "$EVENTS" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T11:30:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
EOF
CORPUS=$(mktemp -d)
MANGLED="-home-context-demo"
mkdir -p "$CORPUS/$MANGLED"
UUID="deadbeef-0000-1111-2222-333344445555"
cat > "$CORPUS/$MANGLED/$UUID.jsonl" <<'EOF'
{"ts":"2026-05-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":4000,"output_tokens":400}}}
EOF

rc=0; out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS" --corpus "$CORPUS" --json) || rc=$?
assert 'rc=0 on happy path' "[ $rc -eq 0 ]"
assert 'output valid JSON' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'schema_version == 1' "printf '%s' \"\$out\" | jq -e '.schema_version == 1' >/dev/null"
assert 'tool == time-to-complete-corpus' "printf '%s' \"\$out\" | jq -e '.tool == \"time-to-complete-corpus\"' >/dev/null"
assert 'per_method.none.n == 1' "printf '%s' \"\$out\" | jq -e '.per_method.none.n == 1' >/dev/null"
# Per-session attribution: session has no compact/clear → method=none; wall_clock from project window = 5400s.
assert 'per_method.none.mean_seconds == 5400' "printf '%s' \"\$out\" | jq -e '.per_method.none.mean_seconds == 5400' >/dev/null"
assert 'paired_delta absent (no --paired)' "printf '%s' \"\$out\" | jq -e '(.paired_delta // null) == null' >/dev/null"

# ---- Step 6: filter flags (date, status, workspace inc/exc, method, method-map) ----
EVENTS2=$(mktemp)
cat > "$EVENTS2" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"early","kind":"start","workstream":"main-a","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T11:00:00Z","kind":"project_boundary","payload":{"slug":"early","kind":"end","workstream":"main-a","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-10T10:00:00Z","kind":"project_boundary","payload":{"slug":"late","kind":"start","workstream":"branch-b","terminal_id":"t2","description":""}}
{"ts":"2026-05-10T12:00:00Z","kind":"project_boundary","payload":{"slug":"late","kind":"end","workstream":"branch-b","terminal_id":"t2","status":"abandoned","note":""}}
EOF
CORPUS2=$(mktemp -d)
mkdir -p "$CORPUS2/-home-context-early" "$CORPUS2/-home-context-late"
# early session: no compact → method=none
cat > "$CORPUS2/-home-context-early/aaaa1111.jsonl" <<'EOF'
{"ts":"2026-05-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}
EOF
# late session: compact boundary → method=compact (assistant msg required before compact marker)
cat > "$CORPUS2/-home-context-late/bbbb2222.jsonl" <<'EOF'
{"ts":"2026-05-10T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}
EOF

# --date-from boundary (excludes earlier project).
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --date-from 2026-05-05T00:00:00Z --json)
assert '--date-from drops early project' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] | contains([\"early\"]) | not' >/dev/null"
assert '--date-from keeps late project' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] | contains([\"late\"])' >/dev/null"

# --date-to boundary (excludes later project).
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --date-to 2026-05-05T00:00:00Z --json)
assert '--date-to drops late project' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] | contains([\"late\"]) | not' >/dev/null"

# --status filter.
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --status shipped --json)
assert '--status shipped keeps early only' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] == [\"early\"]' >/dev/null"

# --workspace include glob.
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --workspace 'main-*' --json)
assert '--workspace main-* keeps only main-a workstream' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] == [\"early\"]' >/dev/null"

# --workspace-exclude.
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --workspace-exclude 'branch-*' --json)
assert '--workspace-exclude branch-* drops branch-b' "printf '%s' \"\$out\" | jq -e '[.per_method[] | .projects[]] | contains([\"late\"]) | not' >/dev/null"

# --method filter (late session has compact_boundary → method=compact).
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --method compact --json)
assert '--method compact keeps only late' "printf '%s' \"\$out\" | jq -e '.per_method.compact.projects == [\"late\"]' >/dev/null"
assert '--method compact: none key absent' "printf '%s' \"\$out\" | jq -e '(.per_method.none // null) == null' >/dev/null"

# --method-map override (force early to auto-memory).
MAP=$(mktemp)
printf '{"early":"auto-memory"}\n' > "$MAP"
out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS2" --corpus "$CORPUS2" --method-map "$MAP" --json)
assert '--method-map override surfaces auto-memory bucket' "printf '%s' \"\$out\" | jq -e '.per_method[\"auto-memory\"].projects == [\"early\"]' >/dev/null"

# ---- Step 7: --paired flag emits paired_delta block ----
EVENTS3=$(mktemp)
cat > "$EVENTS3" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T11:00:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-02T10:00:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"start","workstream":"main-2","terminal_id":"t2","description":""}}
{"ts":"2026-05-02T11:30:00Z","kind":"project_boundary","payload":{"slug":"demo","kind":"end","workstream":"main-2","terminal_id":"t2","status":"shipped","note":""}}
EOF
CORPUS3=$(mktemp -d)
mkdir -p "$CORPUS3/-home-context-demo"
# run1: compact method (assistant msg required before compact marker)
cat > "$CORPUS3/-home-context-demo/run1.jsonl" <<'EOF'
{"ts":"2026-05-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}
EOF
# run2: no compact → method=none
cat > "$CORPUS3/-home-context-demo/run2.jsonl" <<'EOF'
{"ts":"2026-05-02T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}
EOF

rc=0; out=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS3" --corpus "$CORPUS3" --paired --json) || rc=$?
assert 'paired rc=0' "[ $rc -eq 0 ]"
assert 'paired_delta block present' "printf '%s' \"\$out\" | jq -e '.paired_delta' >/dev/null"
# Per-session inference: run1=compact, run2=none → demo spans 2 methods → paired_delta has 1 entry.
assert 'paired_delta has 1 slug (demo)' "printf '%s' \"\$out\" | jq -e '.paired_delta | length == 1' >/dev/null"
assert 'paired_delta first slug == demo' "printf '%s' \"\$out\" | jq -e '.paired_delta[0].slug == \"demo\"' >/dev/null"

# ---- Step 8: --subset fired filter excludes clean sessions (per-session attribution) ----
EVENTS4=$(mktemp)
cat > "$EVENTS4" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"p-mix","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T12:00:00Z","kind":"project_boundary","payload":{"slug":"p-mix","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
EOF
CORPUS4=$(mktemp -d)
mkdir -p "$CORPUS4/-home-context-mix"
# fired session: assistant msg then compact boundary
printf '{"ts":"2026-05-01T10:15:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true}}\n' \
  > "$CORPUS4/-home-context-mix/sess-fired.jsonl"
# clean session: no compact
printf '{"ts":"2026-05-01T11:15:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n' \
  > "$CORPUS4/-home-context-mix/sess-clean.jsonl"

out_both=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS4" --corpus "$CORPUS4" --subset both --json)
out_fired=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS4" --corpus "$CORPUS4" --subset fired --json)
out_clean=$(bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" --events "$EVENTS4" --corpus "$CORPUS4" --subset clean --json)

# both: compact + none both present (2 sessions, one each method).
assert 'subset=both: 2 methods present' "printf '%s' \"\$out_both\" | jq -e '.per_method | length == 2' >/dev/null"
# fired: only compact session.
assert 'subset=fired: compact only' "printf '%s' \"\$out_fired\" | jq -e '.per_method.compact.n == 1' >/dev/null"
assert 'subset=fired: none method absent' "printf '%s' \"\$out_fired\" | jq -e '(.per_method.none // null) == null' >/dev/null"
# clean: only none session.
assert 'subset=clean: none only' "printf '%s' \"\$out_clean\" | jq -e '.per_method.none.n == 1' >/dev/null"
assert 'subset=clean: compact absent' "printf '%s' \"\$out_clean\" | jq -e '(.per_method.compact // null) == null' >/dev/null"

# ---- T2 / F16: workshop CI method tests (studentized+log default; BCa sensitivity) ----
# Fixture: 3 closed projects → 3 sessions with distinct wall_clock values for bootstrap.
EVENTS_CI=$(mktemp)
CORPUS_CI=$(mktemp -d)
mkdir -p "$CORPUS_CI/-home-context-proj-ci"
cat > "$EVENTS_CI" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"ci-a","kind":"start","workstream":"ws-ci","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T11:00:00Z","kind":"project_boundary","payload":{"slug":"ci-a","kind":"end","workstream":"ws-ci","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-02T10:00:00Z","kind":"project_boundary","payload":{"slug":"ci-b","kind":"start","workstream":"ws-ci","terminal_id":"t1","description":""}}
{"ts":"2026-05-02T12:00:00Z","kind":"project_boundary","payload":{"slug":"ci-b","kind":"end","workstream":"ws-ci","terminal_id":"t1","status":"shipped","note":""}}
{"ts":"2026-05-03T09:00:00Z","kind":"project_boundary","payload":{"slug":"ci-c","kind":"start","workstream":"ws-ci","terminal_id":"t1","description":""}}
{"ts":"2026-05-03T10:30:00Z","kind":"project_boundary","payload":{"slug":"ci-c","kind":"end","workstream":"ws-ci","terminal_id":"t1","status":"shipped","note":""}}
EOF
printf '{"ts":"2026-05-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n' \
  > "$CORPUS_CI/-home-context-proj-ci/sess-a.jsonl"
printf '{"ts":"2026-05-02T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n' \
  > "$CORPUS_CI/-home-context-proj-ci/sess-b.jsonl"
printf '{"ts":"2026-05-03T09:30:00Z","type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":10}}}\n' \
  > "$CORPUS_CI/-home-context-proj-ci/sess-c.jsonl"

ci_out=$(SEED=42 bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS_CI" --corpus "$CORPUS_CI" --rigor workshop --json 2>/dev/null)
if [ -n "$ci_out" ]; then
  ci_methods=$(printf '%s' "$ci_out" | jq -r '[.per_method[]? | select(.ci) | .ci.method] | unique | @json' 2>/dev/null || echo '[]')
  assert 'TTC workshop default CI method = studentized+log' \
    "printf '%s' '$ci_methods' | jq -e '. == [\"studentized+log\"]' >/dev/null 2>&1"
else
  FAIL=$((FAIL+1)); printf 'FAIL: time-to-complete-corpus workshop --json returned empty\n' >&2
fi

bca_out=$(SEED=42 bash "$REPO_ROOT/tools/time-to-complete-corpus.sh" \
  --events "$EVENTS_CI" --corpus "$CORPUS_CI" --rigor workshop --ci-method bca --json 2>/dev/null)
if [ -n "$bca_out" ]; then
  assert 'F16 TTC: --ci-method bca: all CI methods == bca' \
    "printf '%s' \"\$bca_out\" | jq -e '[.per_method[]? | select(.ci) | .ci.method] | all(. == \"bca\")' >/dev/null 2>&1"
else
  FAIL=$((FAIL+1)); printf 'FAIL: time-to-complete-corpus --ci-method bca --json returned empty\n' >&2
fi

printf 'tests: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
