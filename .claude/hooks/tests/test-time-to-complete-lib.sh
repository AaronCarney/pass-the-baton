#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/time-to-complete.sh"

PASS=0; FAIL=0
assert() {
  local label="$1" cond="$2"
  if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label" >&2; fi
}

EVENTS=$(mktemp)
cat > "$EVENTS" <<'EOF'
{"ts":"2026-05-01T10:00:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"start","workstream":"main-1","terminal_id":"t1","description":""}}
{"ts":"2026-05-01T12:30:00Z","kind":"project_boundary","payload":{"slug":"proj-a","kind":"end","workstream":"main-1","terminal_id":"t1","status":"shipped","note":""}}
EOF

rc=0; out=$(time_to_complete::compute_per_project "$EVENTS") || rc=$?
assert 'rc=0 on valid pair' "[ $rc -eq 0 ]"
assert 'output is JSONL valid' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'slug == proj-a' "printf '%s' \"\$out\" | jq -e '.slug == \"proj-a\"' >/dev/null"
# 2h 30m = 9000s
assert 'wall_clock_seconds == 9000' "printf '%s' \"\$out\" | jq -e '.wall_clock_seconds == 9000' >/dev/null"
assert 'status == shipped' "printf '%s' \"\$out\" | jq -e '.status == \"shipped\"' >/dev/null"

# CC20: malformed-line (NUL) between two valid project_boundary records.
# compute_per_project (:21) must still pair the post-NUL start/end.
EVENTS_NUL=$(mktemp)
{
  printf '%s\n' '{"ts":"2026-05-01T08:00:00Z","kind":"project_boundary","payload":{"slug":"proj-pre","kind":"start","workstream":"main-0","terminal_id":"t0","description":""}}'
  printf '\0\0\0\n'
  printf '%s\n' '{"ts":"2026-05-04T10:00:00Z","kind":"project_boundary","payload":{"slug":"proj-post","kind":"start","workstream":"main-4","terminal_id":"t4","description":""}}'
  printf '%s\n' '{"ts":"2026-05-04T11:00:00Z","kind":"project_boundary","payload":{"slug":"proj-post","kind":"end","workstream":"main-4","terminal_id":"t4","status":"shipped","note":""}}'
} > "$EVENTS_NUL"
rc=0; out=$(time_to_complete::compute_per_project "$EVENTS_NUL") || rc=$?
assert 'NUL: compute_per_project rc=0' "[ $rc -eq 0 ]"
assert 'NUL: post-NUL pair (proj-post) emitted' "printf '%s' \"\$out\" | jq -se 'any(.[]; .slug == \"proj-post\")' >/dev/null"
# 1h = 3600s
assert 'NUL: post-NUL wall_clock_seconds == 3600' "printf '%s' \"\$out\" | jq -se 'any(.[]; .slug == \"proj-post\" and .wall_clock_seconds == 3600)' >/dev/null"
rm -f "$EVENTS_NUL"

# Unclosed project (start without matching end) → dropped silently.
EVENTS2=$(mktemp)
cat > "$EVENTS2" <<'EOF'
{"ts":"2026-05-02T10:00:00Z","kind":"project_boundary","payload":{"slug":"proj-b","kind":"start","workstream":"main-2","terminal_id":"t2","description":""}}
{"ts":"2026-05-02T11:00:00Z","kind":"project_boundary","payload":{"slug":"proj-c","kind":"start","workstream":"main-3","terminal_id":"t3","description":""}}
{"ts":"2026-05-02T12:00:00Z","kind":"project_boundary","payload":{"slug":"proj-c","kind":"end","workstream":"main-3","terminal_id":"t3","status":"abandoned","note":""}}
EOF
rc=0; out=$(time_to_complete::compute_per_project "$EVENTS2") || rc=$?
assert 'unclosed-only-corpus rc=0' "[ $rc -eq 0 ]"
n=$(printf '%s\n' "$out" | grep -c '^{')
assert 'only 1 record (proj-c) emitted; proj-b dropped' "[ $n -eq 1 ]"
assert 'emitted record is proj-c' "printf '%s' \"\$out\" | jq -e '.slug == \"proj-c\"' >/dev/null"
assert 'emitted status == abandoned' "printf '%s' \"\$out\" | jq -e '.status == \"abandoned\"' >/dev/null"

# Nonexistent file → rc=1.
rc=0; out=$(time_to_complete::compute_per_project /tmp/nonexistent-$$.jsonl 2>&1) || rc=$?
assert 'nonexistent file → rc=1' "[ $rc -eq 1 ]"
assert 'nonexistent error mentions file path' "printf '%s' \"\$out\" | grep -q 'file not found'"

# ---- Fixture A: synthetic-flat (subdir = slug, filename = session-*.jsonl) ----
# Tests the inner inference rules (compact / clear-only / none) on ONE session at a time.
FIXTURE_A=$(mktemp -d)
mkdir -p "$FIXTURE_A/proj-a" "$FIXTURE_A/proj-b" "$FIXTURE_A/proj-c"
cat > "$FIXTURE_A/proj-a/session-1.jsonl" <<'EOF'
{"ts":"2026-05-01T10:05:00Z","type":"assistant","message":{"usage":{"input_tokens":10000,"output_tokens":1000}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":10000}}
{"type":"assistant","message":{"usage":{"input_tokens":2000,"output_tokens":1000}}}
EOF
cat > "$FIXTURE_A/proj-b/session-1.jsonl" <<'EOF'
{"ts":"2026-05-01T10:05:00Z","type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":500}}}
{"type":"user","content":"/clear"}
{"type":"assistant","message":{"usage":{"input_tokens":3000,"output_tokens":500}}}
EOF
cat > "$FIXTURE_A/proj-c/session-1.jsonl" <<'EOF'
{"ts":"2026-05-01T10:05:00Z","type":"assistant","message":{"usage":{"input_tokens":4000,"output_tokens":400}}}
{"type":"assistant","message":{"usage":{"input_tokens":6000,"output_tokens":600}}}
EOF
assert 'infer_method proj-a session == compact' "[ \"\$(time_to_complete::infer_method \"\$FIXTURE_A/proj-a/session-1.jsonl\")\" = compact ]"
assert 'infer_method proj-b session == clear-only' "[ \"\$(time_to_complete::infer_method \"\$FIXTURE_A/proj-b/session-1.jsonl\")\" = clear-only ]"
assert 'infer_method proj-c session == none' "[ \"\$(time_to_complete::infer_method \"\$FIXTURE_A/proj-c/session-1.jsonl\")\" = none ]"

# ---- Fixture B: production-shape (UUID filenames under workspace-mangled subdir) ----
# Tests find_sessions: globs *.jsonl recursively (depth ≤ 2), filters by first-event ts.
FIXTURE_B=$(mktemp -d)
MANGLED="-home-user-workspace"
mkdir -p "$FIXTURE_B/$MANGLED"
UUID1="4a37224b-1111-2222-3333-444455556666"
UUID2="7d6c749f-aaaa-bbbb-cccc-ddddeeeeffff"
UUID3="22fab0e0-9999-8888-7777-666655554444"
# Session 1: first event ts inside [proj-a window 2026-05-01T10..12]
cat > "$FIXTURE_B/$MANGLED/$UUID1.jsonl" <<'EOF'
{"ts":"2026-05-01T10:30:00Z","type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100}}}
{"type":"system","message":{"compact_boundary":true,"isCompactSummary":true,"pre_compact_tokens":5000}}
EOF
# Session 2: first event ts inside same proj-a window (no compact)
cat > "$FIXTURE_B/$MANGLED/$UUID2.jsonl" <<'EOF'
{"ts":"2026-05-01T11:00:00Z","type":"assistant","message":{"usage":{"input_tokens":1500,"output_tokens":150}}}
EOF
# Session 3: first event ts OUTSIDE proj-a window (later day)
cat > "$FIXTURE_B/$MANGLED/$UUID3.jsonl" <<'EOF'
{"ts":"2026-05-03T10:00:00Z","type":"assistant","message":{"usage":{"input_tokens":2000,"output_tokens":200}}}
EOF
proj_a_rec='{"slug":"proj-a","workstream":"main-1","start_ts":"2026-05-01T10:00:00Z","end_ts":"2026-05-01T12:30:00Z"}'
sessions_a=$(time_to_complete::find_sessions "$proj_a_rec" "$FIXTURE_B")
n_a=$(printf '%s\n' "$sessions_a" | grep -c '\.jsonl$' || true)
assert 'find_sessions proj-a: 2 sessions inside window' "[ $n_a -eq 2 ]"
assert 'find_sessions proj-a: includes UUID1' "printf '%s' \"\$sessions_a\" | grep -q '$UUID1.jsonl'"
assert 'find_sessions proj-a: includes UUID2' "printf '%s' \"\$sessions_a\" | grep -q '$UUID2.jsonl'"
assert 'find_sessions proj-a: excludes out-of-window UUID3' "! printf '%s' \"\$sessions_a\" | grep -q '$UUID3.jsonl'"

# Project window with no overlapping sessions → empty list.
proj_z_rec='{"slug":"proj-z","workstream":"main-z","start_ts":"2025-01-01T00:00:00Z","end_ts":"2025-01-01T01:00:00Z"}'
sessions_z=$(time_to_complete::find_sessions "$proj_z_rec" "$FIXTURE_B")
n_z=$(printf '%s\n' "$sessions_z" | grep -c '\.jsonl$' || true)
assert 'find_sessions no-overlap: 0 sessions' "[ $n_z -eq 0 ]"

# ---- aggregate_per_method ----
# Two compact-method sessions (300s, 600s), both fired-subset.
# One none-method session (1200s), clean-subset.
ANNOT=$(mktemp)
cat > "$ANNOT" <<'EOF'
{"slug":"proj-a","session_id":"s1","method_inferred":"compact","wall_clock_seconds":300,"subset":"fired"}
{"slug":"proj-b","session_id":"s2","method_inferred":"compact","wall_clock_seconds":600,"subset":"fired"}
{"slug":"proj-c","session_id":"s3","method_inferred":"none","wall_clock_seconds":1200,"subset":"clean"}
EOF

out=$(time_to_complete::aggregate_per_method "$ANNOT")
assert 'aggregate JSON valid' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'compact.n == 2' "printf '%s' \"\$out\" | jq -e '.compact.n == 2' >/dev/null"
assert 'compact.mean_seconds == 450' "printf '%s' \"\$out\" | jq -e '.compact.mean_seconds == 450' >/dev/null"
assert 'compact.median_seconds == 450' "printf '%s' \"\$out\" | jq -e '.compact.median_seconds == 450' >/dev/null"
assert 'none.n == 1' "printf '%s' \"\$out\" | jq -e '.none.n == 1' >/dev/null"
assert 'none.mean_seconds == 1200' "printf '%s' \"\$out\" | jq -e '.none.mean_seconds == 1200' >/dev/null"

# --subset fired filter excludes clean-subset session (proj-c).
out2=$(time_to_complete::aggregate_per_method "$ANNOT" --subset fired)
assert 'subset=fired: compact.n == 2' "printf '%s' \"\$out2\" | jq -e '.compact.n == 2' >/dev/null"
assert 'subset=fired: none key absent' "printf '%s' \"\$out2\" | jq -e '(.none // null) == null' >/dev/null"

# Per-subset breakdown - verify both buckets are surfaced under one method when present.
ANNOT_MIX=$(mktemp)
cat > "$ANNOT_MIX" <<'EOF'
{"slug":"proj-a","session_id":"s1","method_inferred":"compact","wall_clock_seconds":300,"subset":"fired"}
{"slug":"proj-a","session_id":"s2","method_inferred":"compact","wall_clock_seconds":900,"subset":"clean"}
EOF
out3=$(time_to_complete::aggregate_per_method "$ANNOT_MIX")
assert 'mixed-subset: compact.n == 2' "printf '%s' \"\$out3\" | jq -e '.compact.n == 2' >/dev/null"
assert 'mixed-subset: by_subset.fired.n == 1' "printf '%s' \"\$out3\" | jq -e '.compact.by_subset.fired.n == 1' >/dev/null"
assert 'mixed-subset: by_subset.clean.n == 1' "printf '%s' \"\$out3\" | jq -e '.compact.by_subset.clean.n == 1' >/dev/null"

# ---- paired_delta ----
# proj-a has 2 sessions under compact (200s + 400s → mean 300s) and 1 session under none (900s).
# proj-b has only compact (one session) → not paired.
ANNOT2=$(mktemp)
cat > "$ANNOT2" <<'EOF'
{"slug":"proj-a","session_id":"s1","method_inferred":"compact","wall_clock_seconds":200,"subset":"fired"}
{"slug":"proj-a","session_id":"s2","method_inferred":"compact","wall_clock_seconds":400,"subset":"fired"}
{"slug":"proj-a","session_id":"s3","method_inferred":"none","wall_clock_seconds":900,"subset":"clean"}
{"slug":"proj-b","session_id":"s4","method_inferred":"compact","wall_clock_seconds":600,"subset":"fired"}
EOF

out=$(time_to_complete::paired_delta "$ANNOT2")
assert 'paired_delta JSON valid' "printf '%s' \"\$out\" | jq -e . >/dev/null"
assert 'one slug in pairs (proj-a)' "printf '%s' \"\$out\" | jq -e 'length == 1' >/dev/null"
assert 'proj-a is the paired slug' "printf '%s' \"\$out\" | jq -e '.[0].slug == \"proj-a\"' >/dev/null"
# Mean-collapsed: compact=300, none=900 → delta = 300 - 900 = -600
assert 'proj-a compact-vs-none delta == -600' "printf '%s' \"\$out\" | jq -e '.[0].pairs[] | select(.method_a == \"compact\" and .method_b == \"none\") | .delta_seconds == -600' >/dev/null"
# ratio = 300/900 = 0.333..
assert 'proj-a compact-vs-none ratio < 0.34' "printf '%s' \"\$out\" | jq -e '.[0].pairs[] | select(.method_a == \"compact\" and .method_b == \"none\") | .ratio < 0.34' >/dev/null"
# Exactly one pair (no same-method duplicate).
assert 'proj-a has exactly 1 pair' "printf '%s' \"\$out\" | jq -e '.[0].pairs | length == 1' >/dev/null"

printf 'tests: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
