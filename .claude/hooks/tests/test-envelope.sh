#!/bin/bash
# Unit tests for lib/envelope.sh - CC2 envelope builder + CC8 redaction + size cap.
# Usage: bash .claude/hooks/tests/test-envelope.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HOOKS_DIR/lib/envelope.sh"

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

# Fresh isolated state dir per scenario.
mkstate() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# ----- disable kill-switch -----
echo "## disable kill-switch"

run_disable() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_EVENT_LOG_DISABLE=1
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "TestEvent" '{"k":"v"}'
    echo "rc=$?" > "$d/rc"
  )
  local rc; rc=$(cat "$d/rc")
  assert "disable: returns 0" "[ '$rc' = 'rc=0' ]"
  assert "disable: no file created" "[ ! -e '$log' ]"
  rm -rf "$d"
}
run_disable

# ----- Group A: schema-version -----
echo
echo "## schema-version"

run_schema() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "TestEvent" '{"k":"v"}'
  )
  local line; line=$(head -n1 "$log")

  # Field present + integer
  local sv; sv=$(printf '%s' "$line" | jq -r '.schema_version')
  assert "schema: field present and integer" "[ '$sv' = '1' ]"
  assert "schema: equals 1" "[ '$sv' = '1' ]"

  # Never quoted: jq -r '.schema_version | type' returns 'number'
  local svt; svt=$(printf '%s' "$line" | jq -r '.schema_version | type')
  assert "schema: never quoted (jq type=number)" "[ '$svt' = 'number' ]"

  # Survives jq -c round trip
  local rt; rt=$(printf '%s' "$line" | jq -c '.' | jq -r '.schema_version')
  assert "schema: survives jq -c round-trip" "[ '$rt' = '1' ]"

  # Top-level (not under .data)
  local nested; nested=$(printf '%s' "$line" | jq -r '.data.schema_version // "absent"')
  assert "schema: at top level (not in .data)" "[ '$nested' = 'absent' ]"

  # Single constant in source
  local count; count=$(grep -c 'schema_version=1' "$LIB")
  assert "schema: single constant in envelope.sh" "[ '$count' = '1' ]"

  rm -rf "$d"
}
run_schema

# ----- Group B: mode-0600 -----
echo
echo "## mode-0600"

run_mode() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "FirstEvent" '{"k":"v"}'
  )
  local mode1; mode1=$(stat -c '%a' "$log")
  assert "mode: first emit creates 0600" "[ '$mode1' = '600' ]"

  # Change mode mid-session, emit again, verify restored
  chmod 0644 "$log"
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    umask 0022
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "SecondEvent" '{"k":"v2"}'
  )
  local mode2; mode2=$(stat -c '%a' "$log")
  assert "mode: second emit preserves/restores 0600" "[ '$mode2' = '600' ]"

  rm -rf "$d"
}
run_mode

# ----- Group C: size-cap -----
echo
echo "## size-cap"

# Emit a line of exactly $target bytes (including trailing newline) by adjusting
# a string-valued .pad field in data. Returns the rc of envelope::emit.
emit_sized() {
  local target="$1" log="$2" state="$3"
  # First, measure overhead with an empty pad to compute pad length.
  local probe_line
  probe_line=$(
    export XDG_STATE_HOME="$state"
    export BATON_EVENT_LOG="/dev/null"
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    # Build the same JSON the emit would use, but suppress writing.
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --argjson sv "$schema_version" --arg ev "E" --arg ts "$ts" \
      --argjson data '{"pad":""}' \
      '{schema_version:$sv, event:$ev, ts:$ts, data:$data}'
  )
  local overhead=$(( ${#probe_line} + 1 ))   # +1 for trailing newline
  local pad_len=$(( target - overhead ))
  if [ "$pad_len" -lt 0 ]; then pad_len=0; fi
  local pad
  pad=$(printf '%*s' "$pad_len" '' | tr ' ' 'x')
  local data_json
  data_json=$(jq -cn --arg p "$pad" '{pad:$p}')

  local rc
  (
    export XDG_STATE_HOME="$state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "E" "$data_json" 2>"$state/stderr.$target"
    echo $? > "$state/rc.$target"
  )
  rc=$(cat "$state/rc.$target")
  echo "$rc"
}

run_size_cap() {
  for target in 511 512 513 4095 4096 4097; do
    local d; d=$(mkstate)
    local log="$d/hook-events.jsonl"
    local rc; rc=$(emit_sized "$target" "$log" "$d")

    if [ "$target" -le 4096 ]; then
      assert "size: ${target}B writes successfully (rc=0)" "[ '$rc' = '0' ]"
    else
      # 4097: hard-error path - single combined assertion
      local line; line=$(tail -n1 "$log")
      local trunc; trunc=$(printf '%s' "$line" | jq -r '.truncated // false')
      local orig; orig=$(printf '%s' "$line" | jq -r '.original_bytes // 0')
      local stderr_content; stderr_content=$(cat "$d/stderr.$target")
      local stderr_match=0
      echo "$stderr_content" | grep -q 'baton: event truncated' && stderr_match=1
      assert "size: 4097B hard-error (rc=1, truncated:true, original_bytes:4097, stderr msg)" \
        "[ '$rc' = '1' ] && [ '$trunc' = 'true' ] && [ '$orig' = '4097' ] && [ '$stderr_match' = '1' ]"
    fi
    rm -rf "$d"
  done
}
run_size_cap

# ----- Group D: redaction -----
echo
echo "## redaction"

emit_capture() {
  local data_json="$1"
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "RedactTest" "$data_json"
  )
  tail -n1 "$log"
  rm -rf "$d"
}

run_redaction() {
  local line

  line=$(emit_capture '{"prompt":"secret-text","keep":"ok"}')
  local rv; rv=$(printf '%s' "$line" | jq -r '.data.prompt // "absent"')
  assert "redact: prompt stripped" "[ '$rv' = 'absent' ]"

  line=$(emit_capture '{"completion":"secret-text","keep":"ok"}')
  rv=$(printf '%s' "$line" | jq -r '.data.completion // "absent"')
  assert "redact: completion stripped" "[ '$rv' = 'absent' ]"

  line=$(emit_capture '{"content":"secret-text","keep":"ok"}')
  rv=$(printf '%s' "$line" | jq -r '.data.content // "absent"')
  assert "redact: content stripped" "[ '$rv' = 'absent' ]"

  line=$(emit_capture '{"text":"secret-text","keep":"ok"}')
  rv=$(printf '%s' "$line" | jq -r '.data.text // "absent"')
  assert "redact: text stripped" "[ '$rv' = 'absent' ]"

  line=$(emit_capture '{"message":"m","messages":["a","b"],"keep":"ok"}')
  local msg; msg=$(printf '%s' "$line" | jq -r '.data.message // "absent"')
  local msgs; msgs=$(printf '%s' "$line" | jq -r '.data.messages // "absent"')
  assert "redact: message and messages stripped" "[ '$msg' = 'absent' ] && [ '$msgs' = 'absent' ]"

  line=$(emit_capture '{"response":"secret-text","keep":"ok"}')
  rv=$(printf '%s' "$line" | jq -r '.data.response // "absent"')
  assert "redact: response stripped" "[ '$rv' = 'absent' ]"

  # args/arguments/tool_input collapsed to {arg_count, total_bytes, first64}.
  # No reversible full-value copy is stored (CC8: the redactor must not retain a
  # decodable copy of the arg blob; first64 is the bounded debug peek).
  line=$(emit_capture '{"args":["one","two","three"],"keep":"ok"}')
  local ac; ac=$(printf '%s' "$line" | jq -r '.data.args.arg_count // "missing"')
  local has_b64; has_b64=$(printf '%s' "$line" | jq -r '.data.args.sha256 // .data.args.b64 // "absent"')
  local has_tb;  has_tb=$(printf '%s' "$line" | jq -r '.data.args.total_bytes // "missing"')
  local has_f64; has_f64=$(printf '%s' "$line" | jq -r '.data.args.first64 // "missing"')
  assert "redact: args collapsed to summary {arg_count,total_bytes,first64}, no reversible blob" \
    "[ '$ac' = '3' ] && [ '$has_b64' = 'absent' ] && [ '$has_tb' != 'missing' ] && [ '$has_f64' != 'missing' ]"

  # Absolute path replaced with basename
  line=$(emit_capture '{"file":"/home/foo/bar.txt"}')
  local fv; fv=$(printf '%s' "$line" | jq -r '.data.file')
  assert "redact: absolute path replaced with basename" "[ '$fv' = 'bar.txt' ]"
}
run_redaction

# ----- Group E: torn-line -----
echo
echo "## torn-line"

run_torn() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  mkdir -p "$(dirname "$log")"
  # Pre-seed: a valid JSON line with newline, then a torn line WITHOUT trailing newline.
  printf '{"schema_version":1,"event":"Old","ts":"2025-01-01T00:00:00Z","data":{}}\n' >> "$log"
  printf '{"schema_version":1,"event":"Torn","ts":"2025-01-01T00:00:00Z","data":{"x":"' >> "$log"
  chmod 0600 "$log"

  local pre_torn; pre_torn=$(sed -n '2p' "$log")

  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "AfterTorn" '{"k":"v"}'
  )

  # File content as raw bytes
  local raw; raw=$(cat "$log")
  # Last char must be a newline
  local last_byte
  last_byte=$(tail -c1 "$log" | od -An -tx1 | tr -d ' \n')
  assert "torn: new emit ends with \\n" "[ '$last_byte' = '0a' ]"

  # Torn line untouched: second line of file should still equal pre_torn (sed by line still ok, since the third newline makes it line 2)
  # After the emit, the file is: line1\nlineTorn<newemit-content>\n? No - emit appends starting at current EOF.
  # Actually: valid\ntorn(no nl) -> emit appends "newline\n", so it joins to torn line.
  # Expected behavior: emit MUST first ensure file ends with \n, OR accept the join? Spec says "torn line is left untouched (no repair attempted)".
  # So torn line concatenates with new emit. That means after emit, the file has 2 raw lines (valid + torn+new).
  # Re-reading spec: "File has the expected 3 raw lines after the emit (valid + torn-no-newline + new-valid concatenated)".
  # That means raw newline count should be 3: one ending line1, one between torn-no-newline and new-emit, one ending new-emit.
  # So emit must prepend a \n to its own output when current EOF is not \n.
  local nl_count; nl_count=$(tr -dc '\n' < "$log" | wc -c)
  assert "torn: 3 newlines in file (3 raw lines)" "[ '$nl_count' = '3' ]"

  # Torn line still present unmodified (search by characteristic prefix)
  local has_torn=0
  grep -q '"event":"Torn"' "$log" && has_torn=1
  assert "torn: torn line still present (not rewritten)" "[ '$has_torn' = '1' ]"

  # Last line must parse as JSON
  local last_line; last_line=$(tail -n1 "$log")
  local parses=0
  printf '%s' "$last_line" | jq -e '.event == "AfterTorn"' >/dev/null 2>&1 && parses=1
  assert "torn: new emit parses as JSON cleanly" "[ '$parses' = '1' ]"

  rm -rf "$d"
}
run_torn

# ----- Group F: arc-stamp -----
echo
echo "## arc-stamp"

# Write an arc state file for terminal $1 into $2 (projects dir). $3=method, $4=ended(0/1).
write_arc() {
  local term="$1" pdir="$2" method="$3" ended="$4"
  mkdir -p "$pdir"
  if [ "$ended" = "1" ]; then
    jq -cn --arg t "$term" --arg m "$method" \
      '{slug:"arc-x",started_at:"2026-06-08T00:00:00Z",workstream:"ws",terminal_id:$t,method:$m,ended_at:"2026-06-08T01:00:00Z",notes:[]}' \
      > "$pdir/arc-x.json"
  else
    jq -cn --arg t "$term" --arg m "$method" \
      '{slug:"arc-x",started_at:"2026-06-08T00:00:00Z",workstream:"ws",terminal_id:$t,method:$m,notes:[]}' \
      > "$pdir/arc-x.json"
  fi
}

# open arc stamps slug+method
run_arc_open() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "none" 0
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "demo_event" '{"k":"v"}'
  )
  assert "arc: open arc stamps project_slug" "[ \"\$(tail -1 '$log' | jq -r .data.project_slug)\" = arc-x ]"
  assert "arc: open arc stamps method=none" "[ \"\$(tail -1 '$log' | jq -r .data.method)\" = none ]"
  assert "arc: original data preserved" "[ \"\$(tail -1 '$log' | jq -r .data.k)\" = v ]"
  rm -rf "$d"
}
run_arc_open

# EMPTY-method arc stamps slug + empty method
run_arc_empty_method() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "" 0
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "demo_event" '{"k":"v"}'
  )
  assert "arc-empty: stamps project_slug" "[ \"\$(tail -1 '$log' | jq -r .data.project_slug)\" = arc-x ]"
  assert "arc-empty: method is empty string (not absent, not none)" "[ \"\$(tail -1 '$log' | jq -r '.data.method')\" = '' ]"
  rm -rf "$d"
}
run_arc_empty_method

# MULTI-SESSION accrual (terminal_id keyed, session-agnostic)
run_arc_multi_session() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "none" 0
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    BATON_SESSION_ID=sess-1 envelope::emit "cost_rollup" '{"k":"v"}'
    BATON_SESSION_ID=sess-2 envelope::emit "cost_rollup" '{"k":"v"}'
  )
  assert "arc-multi: penultimate line stamped" "[ \"\$(tail -2 '$log' | head -1 | jq -r .data.project_slug)\" = arc-x ]"
  assert "arc-multi: last line stamped" "[ \"\$(tail -1 '$log' | jq -r .data.project_slug)\" = arc-x ]"
  rm -rf "$d"
}
run_arc_multi_session

# ended arc -> no stamp
run_arc_ended() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "none" 1
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    export BATON_COLLECT=1
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "demo_event" '{"k":"v"}'
  )
  # E23: collection on so an event lands, but ended arc must not stamp it.
  assert "arc-ended: event landed" "[ \"\$(wc -l < '$log')\" -ge 1 ]"
  assert "arc-ended: no stamp (project_slug absent)" "[ \"\$(tail -1 '$log' | jq -r '.data.project_slug // \"ABSENT\"')\" = ABSENT ]"
  rm -rf "$d"
}
run_arc_ended

# no CLAUDE_TERMINAL_ID -> no stamp
run_arc_no_term() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "none" 0
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export BATON_COLLECT=1
    unset CLAUDE_TERMINAL_ID
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "demo_event" '{"k":"v"}'
  )
  # E23: collection on so an event lands, but with no terminal no arc can stamp it.
  assert "arc-no-term: event landed" "[ \"\$(wc -l < '$log')\" -ge 1 ]"
  assert "arc-no-term: no stamp (project_slug absent)" "[ \"\$(tail -1 '$log' | jq -r '.data.project_slug // \"ABSENT\"')\" = ABSENT ]"
  rm -rf "$d"
}
run_arc_no_term

# disable toggle -> no emission
run_arc_disable() {
  local d; d=$(mkstate)
  local log="$d/hook-events.jsonl"
  local pdir="$d/state/baton/projects"
  write_arc "term-env" "$pdir" "none" 0
  # Seed one line so the file exists and has content to count.
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    unset BATON_EVENT_LOG_DISABLE
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "seed" '{"k":"v"}'
  )
  local before; before=$(wc -l <"$log")
  (
    export XDG_STATE_HOME="$d/state"
    export BATON_EVENT_LOG="$log"
    export CLAUDE_TERMINAL_ID="term-env"
    export BATON_EVENT_LOG_DISABLE=1
    # shellcheck disable=SC1090
    source "$LIB"
    envelope::emit "demo" '{}'
  )
  local after; after=$(wc -l <"$log")
  assert "arc-disable: no emission while disabled" "[ '$before' = '$after' ]"
  rm -rf "$d"
}
run_arc_disable

echo
echo "====================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
