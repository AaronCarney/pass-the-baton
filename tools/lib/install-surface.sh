#!/bin/bash
# tools/lib/install-surface.sh - single source of truth for what install.sh
# copies into a target project's .claude/ tree.
#
# Sourced by tools/install.sh (step 4b), tools/uninstall.sh (step 2c) and
# tools/verify-install.sh (installed-surface check). Defining the surface once
# is the point: the commands channel was missing from install.sh for two
# releases and nothing could notice, because no artifact knew what a complete
# install looks like.
#
# Sourced, never executed. No side effects at source time.

# Skill directories copied into <target>/.claude/skills/. Array, not a string:
# every consumer is bash, and an unquoted string expansion would carry SC2086.
INSTALL_SURFACE_SKILLS=(baton install-baton)

# install_surface_paths <repo_dir>
#
# Prints one target-relative path per line for every FILE that must exist in a
# complete install. Files rather than directories, so a skill directory that is
# present but empty is reported as incomplete rather than passing.
#
# Commands are enumerated by glob, so a file added to commands/ is covered with
# no edit here. Skills are enumerated from INSTALL_SURFACE_SKILLS because
# install.sh copies a fixed pair, not everything under .claude/skills/.
#
# Entries whose source artifact is absent from the repo are skipped: the
# installer would not have copied them, so demanding them in the target would
# report a phantom.
install_surface_paths() {
  local repo="$1" _skill _cmd
  for _skill in "${INSTALL_SURFACE_SKILLS[@]}"; do
    [ -f "$repo/.claude/skills/$_skill/SKILL.md" ] || continue
    printf '.claude/skills/%s/SKILL.md\n' "$_skill"
  done
  for _cmd in "$repo"/commands/*.md; do
    [ -e "$_cmd" ] || continue
    printf '.claude/commands/%s\n' "$(basename "$_cmd")"
  done
}
