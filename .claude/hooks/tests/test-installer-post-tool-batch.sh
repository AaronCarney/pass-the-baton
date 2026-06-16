#!/bin/bash
# Tests for install.sh PostToolBatch hook wiring (E8-T6).
# Extracts the marker-bounded block from install.sh into a tmp file and runs
# it in a sandboxed HOME to avoid touching the real ~/.claude/settings.json.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"
INSTALL_SH="$REPO_DIR/tools/install.sh"

PASSED=0
FAILED=0
FAILED_CASES=()

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASSED=$((PASSED+1)); echo "  PASS  $name"
  else
    FAILED=$((FAILED+1)); FAILED_CASES+=("$name"); echo "  FAIL  $name"
  fi
}

# Extract and run just the E8-T6 marker block from install.sh.
# Uses a sandboxed HOME so it never touches the real settings.
run_install_block() {
  local fake_home="$1" install_prefix="$2" stderr_file="${3:-/dev/null}"
  local block_file; block_file=$(mktemp /tmp/install-block.XXXXXX.sh)
  # Extract lines between the begin/end markers (inclusive stripped).
  awk '/# E8-T6: post-tool-batch hook register begin/{found=1; next}
       /# E8-T6: post-tool-batch hook register end/{found=0; next}
       found' "$INSTALL_SH" > "$block_file"
  # Run with overridden vars in a subshell.
  HOME="$fake_home" \
    INSTALL_PREFIX="$install_prefix" \
    SETTINGS="$fake_home/.claude/settings.json" \
    bash "$block_file" 2>"$stderr_file"
  local rc=$?
  rm -f "$block_file"
  return $rc
}

echo "## tools/install.sh - PostToolBatch hook wiring"

# --- marker presence in install.sh -------------------------------------------
assert "INSTALL-MARKER: E8-T6 begin marker present" \
  "grep -q 'E8-T6: post-tool-batch hook register begin' '$INSTALL_SH'"
assert "INSTALL-MARKER: E8-T6 end marker present" \
  "grep -q 'E8-T6: post-tool-batch hook register end' '$INSTALL_SH'"

# --- empty settings.json → PostToolBatch entry added ------------------------
run_empty_settings() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  local cmd
  cmd=$(jq -r '.hooks.PostToolBatch[0].hooks[0].command' "$d/.claude/settings.json" 2>/dev/null)
  assert "EMPTY-SETTINGS: command ends in /post-tool-batch.sh" \
    "[[ '$cmd' == */post-tool-batch.sh ]]"
  rm -rf "$d"
}
run_empty_settings

# --- pre-existing unrelated hooks preserved ----------------------------------
run_preserve_existing() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  cat > "$d/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "/usr/local/bin/custom-hook.sh"}]}]
  }
}
JSON
  run_install_block "$d" "$prefix"
  # Check SessionStart is preserved.
  assert "PRESERVE-EXISTING: SessionStart hook preserved" \
    "jq -e '.hooks.SessionStart[0].hooks[0].command==\"/usr/local/bin/custom-hook.sh\"' '$d/.claude/settings.json' >/dev/null 2>&1"
  # Check PostToolBatch was added.
  assert "PRESERVE-EXISTING: PostToolBatch added alongside" \
    "jq -e '.hooks.PostToolBatch | length > 0' '$d/.claude/settings.json' >/dev/null 2>&1"
  rm -rf "$d"
}
run_preserve_existing

# --- idempotency: running twice does not duplicate PostToolBatch entry --------
run_idempotent() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  run_install_block "$d" "$prefix"
  local count
  count=$(jq '.hooks.PostToolBatch | length' "$d/.claude/settings.json" 2>/dev/null)
  assert "IDEMPOTENT: exactly 1 PostToolBatch entry after 2 runs" "[ '$count' = '1' ]"
  rm -rf "$d"
}
run_idempotent

# --- missing settings.json → file created with PostToolBatch -----------------
run_missing_settings() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  # No settings.json created - block should create it.
  run_install_block "$d" "$prefix"
  assert "MISSING-SETTINGS: settings.json created" "[ -f '$d/.claude/settings.json' ]"
  assert "MISSING-SETTINGS: contains PostToolBatch entry" \
    "jq -e '.hooks.PostToolBatch | length > 0' '$d/.claude/settings.json' >/dev/null 2>&1"
  rm -rf "$d"
}
run_missing_settings

# --- stderr contains registration message ------------------------------------
run_stderr_message() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  local err; err=$(mktemp)
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix" "$err"
  assert "STDERR-MSG: 'registered PostToolBatch hook' in stderr" \
    "grep -q 'registered PostToolBatch hook' '$err'"
  rm -rf "$d" "$err"
}
run_stderr_message

# --- file mode after install is 0644 -----------------------------------------
run_file_mode() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_install_block "$d" "$prefix"
  local mode; mode=$(stat -c '%a' "$d/.claude/settings.json" 2>/dev/null)
  assert "FILE-MODE: settings.json mode is 0644 after install" "[ '$mode' = '644' ]"
  rm -rf "$d"
}
run_file_mode

# --- SubagentStop wiring: install registers, uninstall strips ----------------
UNINSTALL_SH="$REPO_DIR/tools/uninstall.sh"

assert "INSTALL-MARKER: SubagentStop begin marker present" \
  "grep -q 'SubagentStop hook register begin' '$INSTALL_SH'"
assert "INSTALL-MARKER: SubagentStop end marker present" \
  "grep -q 'SubagentStop hook register end' '$INSTALL_SH'"

# Extract and run just the SubagentStop register block from install.sh.
run_subagent_install_block() {
  local fake_home="$1" install_prefix="$2"
  local block_file; block_file=$(mktemp /tmp/install-ssc-block.XXXXXX.sh)
  awk '/# SubagentStop hook register begin/{found=1; next}
       /# SubagentStop hook register end/{found=0; next}
       found' "$INSTALL_SH" > "$block_file"
  HOME="$fake_home" \
    INSTALL_PREFIX="$install_prefix" \
    SETTINGS="$fake_home/.claude/settings.json" \
    bash "$block_file" 2>/dev/null
  rm -f "$block_file"
}

# Extract and run just the strip jq block from uninstall.sh.
run_uninstall_strip_block() {
  local fake_home="$1" repo="$2"
  local settings="$fake_home/.claude/settings.json"
  local _ptb_cmd="bash $repo/.claude/hooks/post-tool-batch.sh"
  local _tt_cmd="bash $repo/.claude/hooks/tool-timing.sh"
  local _ssc_cmd="bash $repo/.claude/hooks/post-subagent-cost.sh"
  jq --arg ptb "$_ptb_cmd" --arg tt "$_tt_cmd" --arg ssc "$_ssc_cmd" '
    if .hooks.PostToolBatch then
      .hooks.PostToolBatch |= map(select((.hooks // []) | map(.command) | index($ptb) | not))
      | if (.hooks.PostToolBatch | length) == 0 then del(.hooks.PostToolBatch) else . end
    else . end
    | if .hooks.PostToolUse then
        .hooks.PostToolUse |= map(select((.hooks // []) | map(.command) | index($tt) | not))
        | if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end
      else . end
    | if .hooks.SubagentStop then
        .hooks.SubagentStop |= map(select((.hooks // []) | map(.command) | index($ssc) | not))
        | if (.hooks.SubagentStop | length) == 0 then del(.hooks.SubagentStop) else . end
      else . end
  ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
}

run_subagent_roundtrip() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_subagent_install_block "$d" "$prefix"
  local cmd
  cmd=$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$d/.claude/settings.json" 2>/dev/null)
  assert "SUBAGENT-INSTALL: command ends in /post-subagent-cost.sh" \
    "[[ '$cmd' == */post-subagent-cost.sh ]]"
  # Uninstall must strip by the same command path the install block wrote.
  run_uninstall_strip_block "$d" "$prefix"
  assert "SUBAGENT-UNINSTALL: SubagentStop key removed after strip" \
    "jq -e '.hooks | has(\"SubagentStop\") | not' '$d/.claude/settings.json' >/dev/null 2>&1"
  rm -rf "$d"
}
run_subagent_roundtrip

# Idempotency of the SubagentStop install block.
run_subagent_idempotent() {
  local d; d=$(mktemp -d)
  local prefix="$d/install"
  mkdir -p "$d/.claude" "$prefix/.claude/hooks"
  printf '{}' > "$d/.claude/settings.json"
  run_subagent_install_block "$d" "$prefix"
  run_subagent_install_block "$d" "$prefix"
  local count
  count=$(jq '.hooks.SubagentStop | length' "$d/.claude/settings.json" 2>/dev/null)
  assert "SUBAGENT-IDEMPOTENT: exactly 1 SubagentStop entry after 2 runs" "[ '$count' = '1' ]"
  rm -rf "$d"
}
run_subagent_idempotent

# Uninstall strip marker present in uninstall.sh.
assert "UNINSTALL-MARKER: post-subagent-cost strip present" \
  "grep -q 'post-subagent-cost.sh' '$UNINSTALL_SH'"

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"

# =============================================================================
# E19 T6: /clear sentinel + summary_turn labeling + running-mean state.
# Self-contained harness (own TMP/REPO/XDG_STATE_HOME/PASS/FAIL/_aeq) appended
# to the installer-wiring suite above. Failures here fold into the final exit.
# =============================================================================
echo ""
echo "## E19 T6 - /clear sentinel + summary_turn labeling"
REPO="$REPO_DIR"
TMP=$(mktemp -d)
export XDG_STATE_HOME="$TMP/state"
export BATON_COLLECT=1
mkdir -p "$XDG_STATE_HOME/baton"
PASS=0; FAIL=0
_aeq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: expected %q got %q (%s)\n' "$1" "$2" "${3:-}" >&2; fi; }

# === E19 T6: sentinel + summary_turn labeling ===
test_e19_sentinel() {
  local SESSION_A=sentinel-A SESSION_B=sentinel-B
  local TRANSCRIPT_A="$TMP/sentinel-A.jsonl" TRANSCRIPT_B="$TMP/sentinel-B.jsonl"
  : > "$TRANSCRIPT_A"; : > "$TRANSCRIPT_B"
  for i in 1 2 3 4 5; do
    printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_A"
    printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_A" "$TRANSCRIPT_A" | bash "$REPO/.claude/hooks/post-tool-batch.sh"
  done
  local sentstate="${XDG_STATE_HOME}/baton/clear-sentinel-state.json"
  local turn_a=$(jq -r --arg s "$SESSION_A" '.[$s].last_turn_index // 0' "$sentstate" 2>/dev/null || echo 0)
  _aeq '5' "$turn_a" 'monotonic: session A last_turn_index=5 after 5 turns'
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":900,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_B"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_B" "$TRANSCRIPT_B" | bash "$REPO/.claude/hooks/post-tool-batch.sh"
  local log="${XDG_STATE_HOME}/baton/hook-events.jsonl"
  local first_b=$(grep "\"session_id\":\"$SESSION_B\"" "$log" | head -1 | jq -r '.data.summary_turn // false')
  _aeq 'false' "$first_b" 'first turn of new session B: summary_turn=false'
  : > "$TRANSCRIPT_A"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":12000,"output_tokens":3200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_A"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_A" "$TRANSCRIPT_A" | bash "$REPO/.claude/hooks/post-tool-batch.sh"
  local last_a=$(grep "\"session_id\":\"$SESSION_A\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'true' "$last_a" 'A post-/clear turn tagged summary_turn=true'
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":900,"output_tokens":400,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_B"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_B" "$TRANSCRIPT_B" | bash "$REPO/.claude/hooks/post-tool-batch.sh"
  local b_last=$(grep "\"session_id\":\"$SESSION_B\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'false' "$b_last" 'B turn after A /clear: B unaffected'
  local recorded=$(jq -r .mean "${XDG_STATE_HOME}/baton/summary-tokens-mean.json")
  _aeq '3200' "$recorded" 'summary tokens recorded in running mean'
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_A"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_A" "$TRANSCRIPT_A" | bash "$REPO/.claude/hooks/post-tool-batch.sh"
  local a_post=$(grep "\"session_id\":\"$SESSION_A\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'false' "$a_post" 'second post-/clear A turn not tagged'
}
test_e19_sentinel

# === E19 T6 iter-3: additional coverage ===

# Case: no-prior-state graceful exit (sentinel state file missing).
test_e19_no_prior_state() {
  local FRESH="$TMP/fresh-state"
  rm -rf "$FRESH"; mkdir -p "$FRESH"
  local SESSION_C=fresh-C TRANSCRIPT_C="$TMP/fresh-C.jsonl"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRANSCRIPT_C"
  set +e
  ( export XDG_STATE_HOME="$FRESH"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_C" "$TRANSCRIPT_C" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local rc=$?
  set -e
  _aeq '0' "$rc" 'no-prior-state branch: hook exits 0 (summary_turn_bool initialized false)'
}
test_e19_no_prior_state

# Case: skill_hash sourced from lib/config.sh - XDG_CONFIG_HOME with template=custom.
test_e19_skill_hash_from_config() {
  local CFG="$TMP/cfg-custom"
  mkdir -p "$CFG/baton"
  printf '{"template":"custom"}\n' > "$CFG/baton/config.json"
  local FRESH2="$TMP/fresh-state-2"; rm -rf "$FRESH2"; mkdir -p "$FRESH2"
  local SESSION_D=skill-D TRANSCRIPT_D="$TMP/skill-D.jsonl"
  for i in 1 2; do
    printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_D"
    ( export XDG_CONFIG_HOME="$CFG"; export XDG_STATE_HOME="$FRESH2"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_D" "$TRANSCRIPT_D" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  done
  : > "$TRANSCRIPT_D"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":4000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_D"
  ( export XDG_CONFIG_HOME="$CFG"; export XDG_STATE_HOME="$FRESH2"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_D" "$TRANSCRIPT_D" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local stm="$FRESH2/baton/summary-tokens-mean.json"
  local recorded_hash=$(jq -r '.skill_hash' "$stm")
  _aeq 'custom' "$recorded_hash" 'config.json template=custom propagated to skill_hash (not default free)'
}
test_e19_skill_hash_from_config

# Case: turn_index equality boundary (post-/clear + single-turn lands at same index).
test_e19_equality_boundary() {
  local FRESH3="$TMP/fresh-state-3"; rm -rf "$FRESH3"; mkdir -p "$FRESH3"
  local SESSION_E=eq-E TRANSCRIPT_E="$TMP/eq-E.jsonl"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRANSCRIPT_E"
  ( export XDG_STATE_HOME="$FRESH3"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_E" "$TRANSCRIPT_E" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  : > "$TRANSCRIPT_E"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":4000,"output_tokens":1500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_E"
  ( export XDG_STATE_HOME="$FRESH3"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_E" "$TRANSCRIPT_E" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local log="$FRESH3/baton/hook-events.jsonl"
  local last_e=$(grep "\"session_id\":\"$SESSION_E\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'false' "$last_e" 'turn_index == prior (equality) is NOT a summary turn (strict-less only)'
}
test_e19_equality_boundary

# Case: zero-output_tokens summary turn - sentinel fires but _stm::update is SKIPPED.
test_e19_zero_output_skip_update() {
  local FRESH4="$TMP/fresh-state-4"; rm -rf "$FRESH4"; mkdir -p "$FRESH4/baton"
  local SESSION_F=zero-F TRANSCRIPT_F="$TMP/zero-F.jsonl"
  printf '{"n":1,"mean":4000,"skill_hash":"free"}' > "$FRESH4/baton/summary-tokens-mean.json"
  for i in 1 2 3; do
    printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_F"
    ( export XDG_STATE_HOME="$FRESH4"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_F" "$TRANSCRIPT_F" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  done
  : > "$TRANSCRIPT_F"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_F"
  ( export XDG_STATE_HOME="$FRESH4"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_F" "$TRANSCRIPT_F" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local log="$FRESH4/baton/hook-events.jsonl"
  local last_f=$(grep "\"session_id\":\"$SESSION_F\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'true' "$last_f" 'zero-output summary turn still tagged summary_turn=true (detection independent of update)'
  local stm="$FRESH4/baton/summary-tokens-mean.json"
  local n=$(jq -r '.n' "$stm")
  local mean=$(jq -r '.mean' "$stm")
  _aeq '1' "$n" 'zero-output: pre-seeded n=1 unchanged after skip'
  _aeq '4000' "$mean" 'zero-output: pre-seeded mean=4000 unchanged after skip'
  # Plan-snippet fix: a *second consecutive* index-1 turn is equality (not a drop),
  # so under strict-less boundary semantics it is NOT a summary turn and would not
  # update. To exercise the "skip did not poison state" assertion the follow-on must
  # be a genuine summary turn (a real turn_index DROP). Climb the index with two
  # non-summary turns first, then truncate so the next turn drops below them.
  for j in 1 2; do
    printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_F"
    ( export XDG_STATE_HOME="$FRESH4"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_F" "$TRANSCRIPT_F" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  done
  : > "$TRANSCRIPT_F"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":6000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$TRANSCRIPT_F"
  ( export XDG_STATE_HOME="$FRESH4"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_F" "$TRANSCRIPT_F" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local n_after=$(jq -r '.n' "$stm")
  local mean_after=$(jq -r '.mean' "$stm")
  _aeq '2' "$n_after" 'post-skip: non-zero follow-on advances n from 1 to 2 (skip did not poison state)'
  _aeq '5000' "$mean_after" 'post-skip: running mean = (4000+6000)/2 = 5000'
}
test_e19_zero_output_skip_update

# Case: corrupt clear-sentinel-state.json - hook recovers, summary_turn=false, state rewritten valid.
test_e19_corrupt_sentinel_state() {
  local FRESH5="$TMP/fresh-state-5"; rm -rf "$FRESH5"; mkdir -p "$FRESH5/baton"
  local SESSION_G=corrupt-G TRANSCRIPT_G="$TMP/corrupt-G.jsonl"
  printf 'not valid json {{{' > "$FRESH5/baton/clear-sentinel-state.json"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRANSCRIPT_G"
  set +e
  ( export XDG_STATE_HOME="$FRESH5"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_G" "$TRANSCRIPT_G" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local rc=$?
  set -e
  _aeq '0' "$rc" 'corrupt-state: hook exits 0 (graceful recovery)'
  local log="$FRESH5/baton/hook-events.jsonl"
  local last_g=$(grep "\"session_id\":\"$SESSION_G\"" "$log" | tail -1 | jq -r '.data.summary_turn // false')
  _aeq 'false' "$last_g" 'corrupt-state: summary_turn=false (no prior valid index)'
  local sentstate="$FRESH5/baton/clear-sentinel-state.json"
  jq -e . "$sentstate" >/dev/null 2>&1 && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: state file not valid JSON after recovery' >&2; }
  local recorded_idx=$(jq -r --arg s "$SESSION_G" '.[$s].last_turn_index // 0' "$sentstate")
  _aeq '1' "$recorded_idx" 'corrupt-state: state rewritten with current turn_index'
}
test_e19_corrupt_sentinel_state

# Case: corrupt-state with prior multi-session entries - DOCUMENTS WIPE behavior.
test_e19_corrupt_state_preserves_other_sessions() {
  local FRESH6="$TMP/fresh-state-6"; rm -rf "$FRESH6"; mkdir -p "$FRESH6/baton"
  local SESSION_A2=multi-A TRANSCRIPT_A2="$TMP/multi-A.jsonl"
  printf '{"sessB":{"last_turn_index":3},"sessC":{"last_turn_index":7}}' > "$FRESH6/baton/clear-sentinel-state.json"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRANSCRIPT_A2"
  set +e
  ( export XDG_STATE_HOME="$FRESH6"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_A2" "$TRANSCRIPT_A2" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local rc_pre=$?
  set -e
  _aeq '0' "$rc_pre" 'valid-state read: hook exits 0'
  local sentstate="$FRESH6/baton/clear-sentinel-state.json"
  local b_idx_pre=$(jq -r '.sessB.last_turn_index // "absent"' "$sentstate")
  local c_idx_pre=$(jq -r '.sessC.last_turn_index // "absent"' "$sentstate")
  _aeq '3' "$b_idx_pre" 'valid-state read preserves sessB (regular jq update path)'
  _aeq '7' "$c_idx_pre" 'valid-state read preserves sessC (regular jq update path)'
  printf 'not valid json {{{' > "$sentstate"
  set +e
  ( export XDG_STATE_HOME="$FRESH6"; printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_A2" "$TRANSCRIPT_A2" | bash "$REPO/.claude/hooks/post-tool-batch.sh" )
  local rc=$?
  set -e
  _aeq '0' "$rc" 'corrupt-state with prior multi-session: hook still exits 0'
  jq -e . "$sentstate" >/dev/null 2>&1 && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo 'FAIL: state file not valid JSON after multi-session recovery' >&2; }
  local a_idx=$(jq -r --arg s "$SESSION_A2" '.[$s].last_turn_index // 0' "$sentstate")
  _aeq '1' "$a_idx" 'corrupt-state recovery: current session recorded'
  local b_idx=$(jq -r '.sessB.last_turn_index // "absent"' "$sentstate")
  local c_idx=$(jq -r '.sessC.last_turn_index // "absent"' "$sentstate")
  _aeq 'absent' "$b_idx" 'corrupt-state recovery WIPES sessB (jq -cn build-from-scratch)'
  _aeq 'absent' "$c_idx" 'corrupt-state recovery WIPES sessC (jq -cn build-from-scratch)'
}
test_e19_corrupt_state_preserves_other_sessions

rm -rf "$TMP"
echo "E19 T6: PASS=$PASS FAIL=$FAIL"

if [ "$FAILED" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
  if [ "$FAILED" -gt 0 ]; then
    echo "Failed installer-wiring:"
    for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  fi
  exit 1
fi
exit 0
