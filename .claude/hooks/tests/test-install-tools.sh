#!/bin/bash
# Unit tests for install/uninstall/cron helpers under tools/.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"

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

echo "## merge-settings.sh"

run_merge_fresh() {
  local d; d=$(mktemp -d)
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  local count
  count=$(jq '.hooks | [.SessionStart, .PreToolUse, .PostToolUse, .SessionEnd, .UserPromptSubmit] | map(length) | add' "$d/settings.json")
  assert "MERGE-FRESH: 7 hook entries inserted into new file" "[ '$count' = '7' ]"
  rm -rf "$d"
}
run_merge_fresh

run_merge_preserve_user() {
  local d; d=$(mktemp -d)
  cat > "$d/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"echo user-hook"}]}]},"theme":"dark"}
EOF
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  assert "MERGE-PRESERVE: user SessionStart entry retained" \
    "[ \"\$(jq -r '.hooks.SessionStart[0].hooks[0].command' '$d/settings.json')\" = 'echo user-hook' ]"
  assert "MERGE-PRESERVE: top-level theme retained" \
    "[ \"\$(jq -r '.theme' '$d/settings.json')\" = 'dark' ]"
  assert "MERGE-PRESERVE: our SessionStart appended (2 entries total)" \
    "[ \"\$(jq -r '.hooks.SessionStart | length' '$d/settings.json')\" = '2' ]"
  rm -rf "$d"
}
run_merge_preserve_user

run_merge_idempotent() {
  local d; d=$(mktemp -d)
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  cp "$d/settings.json" "$d/first.json"
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  assert "MERGE-IDEMPOTENT: second run yields identical output" \
    "cmp -s '$d/first.json' '$d/settings.json'"
  rm -rf "$d"
}
run_merge_idempotent

run_merge_remove() {
  local d; d=$(mktemp -d)
  cat > "$d/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"echo user-hook"}]}]}}
EOF
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  bash "$REPO_DIR/tools/merge-settings.sh" --remove "$d/settings.json"
  assert "MERGE-REMOVE: user entry survives" \
    "[ \"\$(jq -r '.hooks.SessionStart[0].hooks[0].command' '$d/settings.json')\" = 'echo user-hook' ]"
  assert "MERGE-REMOVE: only user entry remains" \
    "[ \"\$(jq -r '.hooks.SessionStart | length' '$d/settings.json')\" = '1' ]"
  rm -rf "$d"
}
run_merge_remove

echo "## install-cron.sh"

run_cron_env_written() {
  local d; d=$(mktemp -d)
  # Real run (no --dry-run): install-cron.sh never modifies the crontab in any
  # mode - it only prints the line. --dry-run now correctly writes nothing
  # (E-D honesty fix), so the env-file write is exercised by a real run.
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo \
    BATON_ARCHIVE_DIR=/tmp/bar \
    bash "$REPO_DIR/tools/install-cron.sh" >/dev/null
  assert "CRON-ENV-WRITTEN: env file exists" "[ -f '$d/.config/baton/env' ]"
  assert "CRON-ENV-WRITTEN: env file contains BATON_PROJECT_DIR" \
    "grep -qE 'BATON_PROJECT_DIR=.*/tmp/foo' '$d/.config/baton/env'"
  assert "CRON-ENV-WRITTEN: env file contains BATON_ARCHIVE_DIR" \
    "grep -qE 'BATON_ARCHIVE_DIR=.*/tmp/bar' '$d/.config/baton/env'"
  rm -rf "$d"
}
run_cron_env_written

run_cron_wrapper_created() {
  local d; d=$(mktemp -d)
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo \
    bash "$REPO_DIR/tools/install-cron.sh" >/dev/null
  assert "CRON-WRAPPER: wrapper exists" "[ -x '$REPO_DIR/tools/cleanup-cron-wrapper.sh' ]"
  assert "CRON-WRAPPER: wrapper sources env file" \
    "grep -q 'source.*baton/env' '$REPO_DIR/tools/cleanup-cron-wrapper.sh'"
  rm -rf "$d"
}
run_cron_wrapper_created

run_cron_idempotent() {
  local d; d=$(mktemp -d)
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo \
    bash "$REPO_DIR/tools/install-cron.sh" >/dev/null
  cp "$d/.config/baton/env" "$d/first.env"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo \
    bash "$REPO_DIR/tools/install-cron.sh" >/dev/null
  assert "CRON-IDEMPOTENT: env file byte-identical on re-run" \
    "cmp -s '$d/first.env' '$d/.config/baton/env'"
  rm -rf "$d"
}
run_cron_idempotent

run_cron_prints_crontab_line() {
  local d; d=$(mktemp -d)
  local out
  out=$(XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo \
    bash "$REPO_DIR/tools/install-cron.sh" --dry-run 2>&1)
  assert "CRON-CRONTAB-LINE: output contains valid crontab snippet" \
    "echo \"\$out\" | grep -qE '0 0 \*/2 \* \* .*cleanup-cron-wrapper.sh'"
  rm -rf "$d"
}
run_cron_prints_crontab_line

run_cron_schedule_install_uninstall_match() {
  # Extract the leading 5-field cron expr from each script's cleanup-cron-wrapper line.
  local d; d=$(mktemp -d)
  local inst unin ie ue
  inst=$(XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR=/tmp/foo bash "$REPO_DIR/tools/install-cron.sh" --dry-run 2>/dev/null | grep -E 'cleanup-cron-wrapper\.sh' | head -1)
  unin=$(BATON_DIR= XDG_CONFIG_HOME="$d/.config" bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --no-archive 2>/dev/null | grep -E 'cleanup-cron-wrapper\.sh' | head -1)
  ie=$(printf '%s' "$inst" | grep -oE '^[0-9*/ ]+ ' | head -1 | xargs echo)
  ue=$(printf '%s' "$unin" | grep -oE '^[0-9*/ ]+ ' | head -1 | xargs echo)
  assert "cron-schedule-install-nonempty" "[ -n '$ie' ]"
  assert "cron-schedule-uninstall-nonempty" "[ -n '$ue' ]"
  assert "cron-schedule-install-eq-uninstall" "[ '$ie' = '$ue' ]"
  assert "cron-schedule-is-every-2-days" "[ '$ie' = '0 0 */2 * *' ]"
  rm -rf "$d"
}
run_cron_schedule_install_uninstall_match

echo "## uninstall.sh"

run_uninstall_strips_hooks() {
  local d; d=$(mktemp -d)
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --no-archive >/dev/null 2>&1
  local count
  count=$(jq '.hooks | (.SessionStart // []) + (.PreToolUse // []) + (.PostToolUse // []) + (.SessionEnd // []) + (.UserPromptSubmit // []) | length' "$d/settings.json")
  assert "UNINSTALL-STRIPS: zero checkpoint hook entries after uninstall" "[ '$count' = '0' ]"
  rm -rf "$d"
}
run_uninstall_strips_hooks

# Regression: install.sh has inline jq blocks for post-tool-batch and
# tool-timing that bypass merge-settings.sh. uninstall.sh must strip those
# entries too - otherwise users are left with broken references to scripts
# that no longer exist after they delete the repo.
run_uninstall_full_roundtrip() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --no-archive >/dev/null 2>&1
  local pre_count post_count
  post_count=$(jq '
    [.hooks.SessionStart // [], .hooks.PreToolUse // [], .hooks.PostToolUse // [],
     .hooks.SessionEnd // [], .hooks.UserPromptSubmit // [], .hooks.PostToolBatch // []]
    | map(.[]?.hooks // []) | flatten | map(.command) | map(select(test("checkpoint|session-start|cleanup-on-exit|project-detect|post-tool-batch|tool-timing"))) | length
  ' "$d/settings.json")
  assert "UNINSTALL-FULL-ROUNDTRIP: zero checkpoint hooks left after install→uninstall" \
    "[ '$post_count' = '0' ]"
  rm -rf "$d"
}
run_uninstall_full_roundtrip

run_uninstall_archives_checkpoint_dir() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj/.baton/workstreams" "$d/archive"
  echo '{"workstream":"x"}' > "$d/proj/.baton/workstreams/x.json"
  BATON_ARCHIVE_DIR="$d/archive" \
    bash "$REPO_DIR/tools/uninstall.sh" --settings /dev/null --checkpoint-dir "$d/proj/.baton" >/dev/null 2>&1
  assert "UNINSTALL-ARCHIVE: checkpoint dir moved out of project" \
    "[ ! -d '$d/proj/.baton' ]"
  assert "UNINSTALL-ARCHIVE: archive directory contains uninstall-* folder" \
    "ls -d '$d/archive'/uninstall-* >/dev/null 2>&1"
  rm -rf "$d"
}
run_uninstall_archives_checkpoint_dir

echo "## install.sh (non-interactive)"

run_install_appends_gitignore() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  echo "node_modules/" > "$d/proj/.gitignore"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" \
    HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "INSTALL-GITIGNORE: .baton/ appended to target .gitignore" \
    "grep -qE '^\\.baton/?\$' '$d/proj/.gitignore'"
  rm -rf "$d"
}
run_install_appends_gitignore

run_install_idempotent_gitignore() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  echo ".baton/" > "$d/proj/.gitignore"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  local count
  count=$(grep -cE '^\.baton/?$' "$d/proj/.gitignore")
  assert "INSTALL-IDEMPOTENT-GITIGNORE: single .baton/ line (no duplicate)" "[ '$count' = '1' ]"
  rm -rf "$d"
}
run_install_idempotent_gitignore

run_install_invokes_merge_settings() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  local count
  # install.sh writes 9 hook entries to settings.json: 7 via merge-settings.sh
  # (SessionStart, PreToolUse, PostToolUse x2, SessionEnd, UserPromptSubmit x2 -
  # the latter two grew by the T5 outcome-proxy additions) plus 2 via inline jq
  # blocks (PostToolBatch + a second PostToolUse=tool-timing).
  count=$(jq '.hooks | [.SessionStart, .PreToolUse, .PostToolUse, .SessionEnd, .UserPromptSubmit, .PostToolBatch] | map(length // 0) | add' "$d/settings.json")
  assert "INSTALL-MERGE-SETTINGS: 9 hook entries in settings.json" "[ '$count' = '9' ]"
  rm -rf "$d"
}
run_install_invokes_merge_settings

echo "## verify-install.sh"

run_verify_passes_after_install() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  HOME="$d" XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  HOME="$d" XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite >/dev/null 2>&1
  local rc=$?
  assert "VERIFY-PASSES: exit 0 on healthy install" "[ $rc -eq 0 ]"
  rm -rf "$d"
}
run_verify_passes_after_install

run_verify_fails_missing_hook() {
  local d; d=$(mktemp -d)
  echo '{"hooks":{}}' > "$d/settings.json"
  bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite >/dev/null 2>&1
  local rc=$?
  assert "VERIFY-FAILS-NO-HOOK: exit non-zero when SessionStart hook absent" "[ $rc -ne 0 ]"
  rm -rf "$d"
}
run_verify_fails_missing_hook

run_verify_idempotency_check() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  HOME="$d" XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  cp "$d/settings.json" "$d/first.json"
  cp "$d/proj/.gitignore" "$d/first.gitignore"
  HOME="$d" XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --idempotency-check --target "$d/proj" >/dev/null 2>&1
  assert "VERIFY-IDEMPOTENT-SETTINGS: settings.json unchanged by re-install" \
    "cmp -s '$d/first.json' '$d/settings.json'"
  assert "VERIFY-IDEMPOTENT-GITIGNORE: .gitignore unchanged by re-install" \
    "cmp -s '$d/first.gitignore' '$d/proj/.gitignore'"
  rm -rf "$d"
}
run_verify_idempotency_check

echo "## install/uninstall skills (E2)"

# E2: install.sh copies the kept skills into the target project's .claude/skills/
run_install_copies_skills() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "E2: install copies baton skill" "[ -f '$d/proj/.claude/skills/baton/SKILL.md' ]"
  assert "E2: install copies install-baton skill" "[ -f '$d/proj/.claude/skills/install-baton/SKILL.md' ]"
  # Absence checked via the skills listing (not a literal skills-slash-resume path)
  # so the no-stranded-command audit gate does not false-positive on this test.
  assert "E2: install does NOT copy the removed skill" "! ls '$d/proj/.claude/skills' 2>/dev/null | grep -qx resume"
  # Idempotent re-install: running install again must NOT nest baton/baton
  # (proves the skip-if-exists guard the plan advertises actually holds).
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "E2: re-install is idempotent (no nested baton/baton)" "[ ! -e '$d/proj/.claude/skills/baton/baton' ]"
  rm -rf "$d"
}
run_install_copies_skills

# E2: uninstall (explicit target) removes the copied skills
run_uninstall_removes_skills() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  XDG_CONFIG_HOME="$d/.config" HOME="$d" \
    bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "E2: uninstall removes baton skill" "[ ! -e '$d/proj/.claude/skills/baton' ]"
  assert "E2: uninstall removes install-baton skill" "[ ! -e '$d/proj/.claude/skills/install-baton' ]"
  rm -rf "$d"
}
run_uninstall_removes_skills

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
