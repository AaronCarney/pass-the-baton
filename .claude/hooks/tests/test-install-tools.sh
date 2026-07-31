#!/bin/bash
# Unit tests for install/uninstall/cron helpers under tools/.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/../.." && pwd)"

# Backstop: two tests write a zz-*.md probe into the tracked commands/ dir and
# rm it synchronously before their asserts. If the suite is killed mid-test the
# trap sweeps any stray probe so nothing is stranded in a released directory.
trap 'rm -f "$REPO_DIR"/commands/zz-*.md' EXIT

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
  count=$(jq '.hooks | [.SessionStart, .PreToolUse, .PostToolUse, .SessionEnd, .UserPromptSubmit, .Stop] | map(length) | add' "$d/settings.json")
  assert "MERGE-FRESH: 8 hook entries inserted into new file" "[ '$count' = '8' ]"
  # A count is not enough: map(length)|add counts ENTRIES PER EVENT, so a Stop row
  # paired with the wrong command (typo, or EVENTS/MATCHERS/COMMANDS drifted out of
  # index alignment) still yields exactly one .Stop entry and the count passes at 8.
  # test-plugin-hooks-parity.sh cannot cover this - it reads hooks/hooks.json ONLY,
  # never merge-settings.sh - so without this the installed-settings path (the one
  # real installs use) would have no content gate at all. Mirrors the command/file
  # check that parity test already does for the plugin path.
  local cmd
  cmd=$(jq -r '.hooks.Stop[0].hooks[0].command' "$d/settings.json")
  assert "MERGE-FRESH: Stop command references stop-relaunch-trigger.sh" \
    "echo '$cmd' | grep -q 'stop-relaunch-trigger\.sh'"
  assert "MERGE-FRESH: Stop command resolves to a real file" \
    "[ -f \"\$(echo '$cmd' | awk '{print \$NF}')\" ]"
  rm -rf "$d"
}
run_merge_fresh

run_merge_remove_stop() {
  local d; d=$(mktemp -d)
  bash "$REPO_DIR/tools/merge-settings.sh" "$d/settings.json"
  assert "MERGE-STOP: Stop registered after merge" \
    "[ \"\$(jq -r '.hooks.Stop | length' '$d/settings.json')\" = '1' ]"
  bash "$REPO_DIR/tools/merge-settings.sh" --remove "$d/settings.json"
  assert "MERGE-STOP-REMOVE: Stop key gone after --remove" \
    "[ \"\$(jq -r '.hooks.Stop // \"absent\"' '$d/settings.json')\" = 'absent' ]"
  rm -rf "$d"
}
run_merge_remove_stop

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

# Regression: install.sh step 7 invoked install-cron.sh with --dry-run, so the answers
# it collects and exports ("Export so install-cron picks them up") reached a child that
# by contract writes nothing. Installing produced no env file and no wrapper, and the
# archive-dir answer died there. The installer's cron step must actually install.
run_install_writes_cron_env() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" BATON_ARCHIVE_DIR="$d/archive" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "INSTALL-CRON: installer writes the cron env file" "[ -f '$d/.config/baton/env' ]"
  assert "INSTALL-CRON: env file carries the archive-dir answer" \
    "grep -qE 'BATON_ARCHIVE_DIR=.*$d/archive' '$d/.config/baton/env'"
  # No wrapper assert here: run_cron_wrapper_created above already created it in the
  # shared repo path, so asserting it exists again would pass without proving anything.
  rm -rf "$d"
}
run_install_writes_cron_env

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

echo "## install/uninstall commands"

# install.sh copies commands/ into the target project's .claude/commands/.
run_install_copies_commands() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "CMD: install copies renew command" "[ -f '$d/proj/.claude/commands/renew.md' ]"
  assert "CMD: install copies off command" "[ -f '$d/proj/.claude/commands/off.md' ]"
  assert "CMD: install copies snooze command" "[ -f '$d/proj/.claude/commands/snooze.md' ]"
  # Idempotent re-install: step 4c's [ ! -e ] guard must make a second install a
  # no-op over the command files. A plain before/after content compare cannot
  # see a re-copy of the SAME bytes, so mark one file first - the marker is what
  # a regressed guard would wipe. The other two are compared byte-for-byte
  # against the repo's shipped copies with cmp -s, the instrument
  # run_verify_idempotency_check already uses higher up in this file.
  echo "local edit" >> "$d/proj/.claude/commands/renew.md"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "CMD: re-install does not overwrite an edited command" \
    "grep -q 'local edit' '$d/proj/.claude/commands/renew.md'"
  assert "CMD: re-install leaves off command byte-identical" \
    "cmp -s '$REPO_DIR/commands/off.md' '$d/proj/.claude/commands/off.md'"
  assert "CMD: re-install leaves snooze command byte-identical" \
    "cmp -s '$REPO_DIR/commands/snooze.md' '$d/proj/.claude/commands/snooze.md'"
  rm -rf "$d"
}
run_install_copies_commands

# The target's command dir is shared with the user's own commands (the owner's
# real target holds catchup.md and consolidate.md), so the copy must never
# clobber a name it did not install, and must leave bystanders alone.
run_install_preserves_foreign_commands() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj/.claude/commands"
  echo "mine" > "$d/proj/.claude/commands/catchup.md"
  echo "theirs" > "$d/proj/.claude/commands/renew.md"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "CMD: unrelated command file untouched" \
    "[ \"\$(cat '$d/proj/.claude/commands/catchup.md')\" = 'mine' ]"
  assert "CMD: pre-existing same-name file not overwritten" \
    "[ \"\$(cat '$d/proj/.claude/commands/renew.md')\" = 'theirs' ]"
  rm -rf "$d"
}
run_install_preserves_foreign_commands

# uninstall (explicit target) removes the copied commands and nothing else.
run_uninstall_removes_commands() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  echo "mine" > "$d/proj/.claude/commands/catchup.md"
  XDG_CONFIG_HOME="$d/.config" HOME="$d" \
    bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "CMD: uninstall removes renew command" "[ ! -e '$d/proj/.claude/commands/renew.md' ]"
  assert "CMD: uninstall removes off command" "[ ! -e '$d/proj/.claude/commands/off.md' ]"
  assert "CMD: uninstall removes snooze command" "[ ! -e '$d/proj/.claude/commands/snooze.md' ]"
  assert "CMD: unrelated command file survives uninstall" \
    "[ -f '$d/proj/.claude/commands/catchup.md' ]"
  rm -rf "$d"
}
run_uninstall_removes_commands

# A user's own file that happens to share a name with a shipped command is not
# baton's to delete: install skips it (never wrote it), so uninstall must leave
# it alone. Without a content check, name-matched removal deletes it.
run_uninstall_preserves_same_name_user_command() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj/.claude/commands"
  echo "theirs" > "$d/proj/.claude/commands/renew.md"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  XDG_CONFIG_HOME="$d/.config" HOME="$d" \
    bash "$REPO_DIR/tools/uninstall.sh" --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  assert "CMD: user's same-name command survives uninstall" \
    "[ \"\$(cat '$d/proj/.claude/commands/renew.md')\" = 'theirs' ]"
  assert "CMD: same-name collision does not block removal of the rest" \
    "[ ! -e '$d/proj/.claude/commands/off.md' ]"
  rm -rf "$d"
}
run_uninstall_preserves_same_name_user_command

echo "## install-surface library"

# The library is the single source of truth for what an install produces. Both
# installers and the verifier read it, so its contract is asserted directly
# rather than only through its callers.
run_install_surface_contract() {
  local out
  # shellcheck source=/dev/null
  source "$REPO_DIR/tools/lib/install-surface.sh"
  assert "SURFACE: skills array carries baton" \
    "printf '%s\n' \"\${INSTALL_SURFACE_SKILLS[@]}\" | grep -qx baton"
  assert "SURFACE: skills array carries install-baton" \
    "printf '%s\n' \"\${INSTALL_SURFACE_SKILLS[@]}\" | grep -qx install-baton"
  out=$(install_surface_paths "$REPO_DIR")
  assert "SURFACE: emits baton SKILL.md path" \
    "printf '%s' \"$out\" | grep -qx '.claude/skills/baton/SKILL.md'"
  assert "SURFACE: emits install-baton SKILL.md path" \
    "printf '%s' \"$out\" | grep -qx '.claude/skills/install-baton/SKILL.md'"
  assert "SURFACE: emits every shipped command" \
    "[ \"\$(printf '%s' \"$out\" | grep -c '^.claude/commands/')\" = \"\$(ls '$REPO_DIR'/commands/*.md | wc -l)\" ]"
  assert "SURFACE: emits renew command path" \
    "printf '%s' \"$out\" | grep -qx '.claude/commands/renew.md'"
  # Drift guard: a command added to commands/ must appear with no edit here.
  local tmpcmd="$REPO_DIR/commands/zz-surface-probe.md"
  echo "probe" > "$tmpcmd"
  out=$(install_surface_paths "$REPO_DIR")
  rm -f "$tmpcmd"
  assert "SURFACE: a newly added command is picked up with no edit to the enumerator" \
    "printf '%s' \"$out\" | grep -qx '.claude/commands/zz-surface-probe.md'"
  # Every emitted path must actually resolve inside the repo, or the verifier
  # would demand files that were never shipped.
  local rel bad=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      .claude/skills/*) [ -f "$REPO_DIR/$rel" ] || bad=1 ;;
      .claude/commands/*) [ -f "$REPO_DIR/commands/$(basename "$rel")" ] || bad=1 ;;
    esac
  done <<EOF
$(install_surface_paths "$REPO_DIR")
EOF
  assert "SURFACE: every emitted path resolves to a real repo artifact" "[ $bad -eq 0 ]"
}
run_install_surface_contract

echo "## installers read the shared surface"

# The point of the shared list is that it is the ONLY list. Grep is the direct
# evidence: a literal skill name left in either installer means a second source
# of truth survived the refactor and can drift again.
run_installers_consume_shared_surface() {
  assert "SURFACE-WIRE: install.sh sources the surface lib" \
    "grep -q 'lib/install-surface.sh' '$REPO_DIR/tools/install.sh'"
  assert "SURFACE-WIRE: uninstall.sh sources the surface lib" \
    "grep -q 'lib/install-surface.sh' '$REPO_DIR/tools/uninstall.sh'"
  assert "SURFACE-WIRE: install.sh no longer hardcodes the skill pair" \
    "! grep -q 'for _skill in baton install-baton' '$REPO_DIR/tools/install.sh'"
  assert "SURFACE-WIRE: uninstall.sh no longer hardcodes the skill pair" \
    "! grep -q 'for _skill in baton install-baton' '$REPO_DIR/tools/uninstall.sh'"
  assert "SURFACE-WIRE: install.sh iterates the shared array" \
    "grep -q 'INSTALL_SURFACE_SKILLS\\[@\\]' '$REPO_DIR/tools/install.sh'"
  assert "SURFACE-WIRE: uninstall.sh iterates the shared array" \
    "grep -q 'INSTALL_SURFACE_SKILLS\\[@\\]' '$REPO_DIR/tools/uninstall.sh'"
}
run_installers_consume_shared_surface

echo "## verify-install installed-surface check"

# A complete install must pass the surface check.
run_verify_surface_passes_on_complete_target() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/proj" >/dev/null 2>&1
  local rc=$?
  assert "SURFACE-VERIFY: exit 0 against a freshly installed target" "[ $rc -eq 0 ]"
  rm -rf "$d"
}
run_verify_surface_passes_on_complete_target

# A target missing a command must fail, and the message must name the file -
# a bare count would not tell an installing agent what to fix.
run_verify_surface_fails_on_missing_command() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  rm -f "$d/proj/.claude/commands/renew.md"
  local out rc
  out=$(HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/proj" 2>&1)
  rc=$?
  assert "SURFACE-VERIFY: non-zero exit when a command is missing" "[ $rc -ne 0 ]"
  assert "SURFACE-VERIFY: message names the missing command" \
    "printf '%s' \"$out\" | grep -q 'renew.md'"
  rm -rf "$d"
}
run_verify_surface_fails_on_missing_command

# Partially populated, not merely absent: the skill directory is present but
# its SKILL.md is gone. A directory-existence check would pass this.
run_verify_surface_fails_on_partial_skill() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  rm -f "$d/proj/.claude/skills/baton/SKILL.md"
  local out rc
  out=$(HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/proj" 2>&1)
  rc=$?
  assert "SURFACE-VERIFY: non-zero exit when a skill dir is present but empty" "[ $rc -ne 0 ]"
  assert "SURFACE-VERIFY: message names the missing skill file" \
    "printf '%s' \"$out\" | grep -q 'skills/baton/SKILL.md'"
  rm -rf "$d"
}
run_verify_surface_fails_on_partial_skill

# A wholly absent .claude/ tree is the agent-installed-it-wrong case.
run_verify_surface_fails_on_empty_target() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj" "$d/empty"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/empty" >/dev/null 2>&1
  local rc=$?
  assert "SURFACE-VERIFY: non-zero exit against a target with no .claude tree" "[ $rc -ne 0 ]"
  rm -rf "$d"
}
run_verify_surface_fails_on_empty_target

# Without --target the check must not run at all: TARGET defaults to $PWD,
# which in a dev checkout is the repo and has no .claude/commands/.
run_verify_surface_skipped_without_target() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  local out rc
  out=$(cd "$REPO_DIR" && HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite 2>&1)
  rc=$?
  assert "SURFACE-VERIFY: exit 0 with no --target (surface check skipped)" "[ $rc -eq 0 ]"
  assert "SURFACE-VERIFY: no surface line emitted without --target" \
    "! printf '%s' \"$out\" | grep -q 'installed surface'"
  rm -rf "$d"
}
run_verify_surface_skipped_without_target

# Coverage is enumerator-driven, so a command added later is checked with no
# edit to verify-install.sh. Prove it by adding one and deleting it from an
# otherwise-complete target.
run_verify_surface_covers_new_commands() {
  local d; d=$(mktemp -d); mkdir -p "$d/proj"
  local tmpcmd="$REPO_DIR/commands/zz-verify-probe.md"
  echo "probe" > "$tmpcmd"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  rm -f "$d/proj/.claude/commands/zz-verify-probe.md"
  local out rc
  out=$(HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$REPO_DIR/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/proj" 2>&1)
  rc=$?
  rm -f "$tmpcmd"
  assert "SURFACE-VERIFY: a command added after the check was written is covered" "[ $rc -ne 0 ]"
  assert "SURFACE-VERIFY: message names the newly added command" \
    "printf '%s' \"$out\" | grep -q 'zz-verify-probe.md'"
  rm -rf "$d"
}
run_verify_surface_covers_new_commands

# Vacuous-pass guard: if the enumerator emits zero lines the check must FAIL, not
# report "complete" having verified nothing - that silent pass is the exact shape
# of the original defect. Drive it with a scratch verify whose sibling surface lib
# is stubbed to emit nothing; every other check passes off a real install so only
# the empty enumerator can fail it.
run_verify_surface_fails_on_empty_enumerator() {
  local d; d=$(mktemp -d); mkdir -p "$d/repo/tools/lib"
  XDG_CONFIG_HOME="$d/.config" BATON_PROJECT_DIR="$d/proj" HOME="$d" \
    bash "$REPO_DIR/tools/install.sh" --non-interactive --settings "$d/settings.json" --target "$d/proj" >/dev/null 2>&1
  cp "$REPO_DIR/tools/verify-install.sh" "$d/repo/tools/verify-install.sh"
  printf '%s\n' '#!/bin/bash' 'install_surface_paths() { :; }' > "$d/repo/tools/lib/install-surface.sh"
  local out rc
  out=$(HOME="$d" XDG_CONFIG_HOME="$d/.config" \
    bash "$d/repo/tools/verify-install.sh" --settings "$d/settings.json" --skip-suite --target "$d/proj" 2>&1)
  rc=$?
  assert "SURFACE-VERIFY: non-zero exit when the enumerator emits zero paths" "[ $rc -ne 0 ]"
  assert "SURFACE-VERIFY: message flags the empty enumerator, not a missing file" \
    "printf '%s' \"$out\" | grep -q 'no paths'"
  rm -rf "$d"
}
run_verify_surface_fails_on_empty_enumerator

echo ""
echo "====================================="
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
