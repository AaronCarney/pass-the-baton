#!/usr/bin/env bash
# .claude/hooks/tests/test-corpus.sh - TDD for lib/corpus.sh
set -uo pipefail
export LC_ALL=C
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$_SD/lib/corpus.sh"

PASS=0; FAIL=0
assert() { local name="$1" cond="$2"; if eval "$cond"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/projects/-home-test-alpha" "$TMPROOT/projects/subagents" "$TMPROOT/projects/-home-test-alpha-beta"

write_transcript() {
  local path="$1" turns="$2" i
  : > "$path"
  for ((i=0; i<turns; i++)); do
    printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' >> "$path"
  done
}

write_transcript "$TMPROOT/projects/-home-test-alpha/aaa-111.jsonl" 5
write_transcript "$TMPROOT/projects/-home-test-alpha/bbb-222.jsonl" 3
write_transcript "$TMPROOT/projects/subagents/sub-001.jsonl" 2
write_transcript "$TMPROOT/projects/-home-test-alpha-beta/ow-001.jsonl" 7

out="$(corpus::list "$TMPROOT/projects")"
assert 'default excludes subagents workspace' "[ \$(printf '%s\\n' \"\$out\" | wc -l) -eq 3 ]"
assert 'default does not list subagents transcripts' "! printf '%s\\n' \"\$out\" | grep -q '/subagents/'"

out="$(corpus::list "$TMPROOT/projects" --include-subagents)"
assert 'include-subagents adds them' "[ \$(printf '%s\\n' \"\$out\" | wc -l) -eq 4 ]"

out="$(corpus::list "$TMPROOT/projects" | head -1)"
cols=$(printf '%s' "$out" | awk -F'\t' '{print NF}')
assert '5 TSV columns' "[ \"$cols\" = '5' ]"
assert 'first col is full path' "[[ \"\$out\" == \"$TMPROOT/projects/\"* ]]"
assert 'workspace col is parent dir basename' "printf '%s' \"\$out\" | awk -F'\\t' '{print \$2}' | grep -qE '^-home-test-(alpha|alpha-beta)\$'"
assert 'session_id col is basename without .jsonl' "printf '%s' \"\$out\" | awk -F'\\t' '{print \$3}' | grep -qE '^[a-z]+-[0-9]+\$'"
assert 'bytes col is positive integer' "printf '%s' \"\$out\" | awk -F'\\t' '{exit !(\$4 ~ /^[0-9]+\$/ && \$4+0 > 0)}'"
assert 'turns col is positive integer' "printf '%s' \"\$out\" | awk -F'\\t' '{exit !(\$5 ~ /^[0-9]+\$/ && \$5+0 > 0)}'"

out="$(corpus::list "$TMPROOT/projects" --workspace-include '*alpha')"
assert 'workspace-include glob filters to matches only' "[ \$(printf '%s\\n' \"\$out\" | awk -F'\\t' '{print \$2}' | sort -u | wc -l) -eq 1 ]"

out="$(corpus::list "$TMPROOT/projects" --workspace-exclude '*alpha-beta')"
assert 'workspace-exclude drops the sibling workspace' "! printf '%s\\n' \"\$out\" | grep -q 'alpha-beta'"

out="$(corpus::list "$TMPROOT/projects" --limit 2)"
assert 'limit caps line count' "[ \$(printf '%s\\n' \"\$out\" | wc -l) -eq 2 ]"

out_rc=0; corpus::list "$TMPROOT/does-not-exist" >/dev/null 2>&1 || out_rc=$?
assert 'missing corpus root exits non-zero' "[ \"$out_rc\" -ne 0 ]"

# Robustness: a user-only transcript (no assistant lines) must yield a
# single, well-formed TSV row - not a row split by an embedded newline
# from the underlying grep -c "0 + rc=1 || echo 0" misfire.
TMPROOT_S="$(mktemp -d)"
trap 'rm -rf "$TMPROOT_S"' EXIT
mkdir -p "$TMPROOT_S/projects/ws"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMPROOT_S/projects/ws/user-only.jsonl"
out="$(corpus::list "$TMPROOT_S/projects")"
assert 'user-only transcript yields exactly 1 TSV row' "[ \$(printf '%s\\n' \"\$out\" | wc -l) -eq 1 ]"
turns_col=$(printf '%s' "$out" | awk -F'\t' '{print $5}')
assert 'turns col has no embedded newline (single literal char)' "[ \"\${#turns_col}\" -le 4 ]"
assert 'turns col is exactly 0 for user-only transcript' "[ \"\$turns_col\" = '0' ]"

assert 'no network in lib/corpus.sh' "! grep -E 'curl|wget|\\bnc\\b|/dev/tcp' \"$_SD/lib/corpus.sh\""
assert 'lib/corpus.sh parses' "bash -n \"$_SD/lib/corpus.sh\""

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
