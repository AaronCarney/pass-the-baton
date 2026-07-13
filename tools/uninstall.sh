#!/bin/bash
# uninstall.sh - inverse of install. Strips our hook entries via
# merge-settings.sh --remove, archives the checkpoint state directory, and
# prints the crontab line the user should remove.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"

# shellcheck source=tools/lib/cron-schedule.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/cron-schedule.sh"

SETTINGS=""
BATON_DIR_ARG=""
TARGET_ARG=""
ARCHIVE=1
_print_usage() {
  cat <<'USAGE'
usage: uninstall.sh [--settings <path>] [--checkpoint-dir <path>] [--target <dir>] [--no-archive] [--help]

Modes:
  Soft (default):  strips hook entries from ~/.claude/settings.json only.
                   Leaves project files (.gitignore, cron wrapper, env file) in place.
                   Safe to run from any $PWD - does not touch unrelated repos.

  Full:            additionally removes .baton/ from <target>/.gitignore,
                   the cron wrapper at <repo>/tools/cleanup-cron-wrapper.sh, and
                   the env file at $XDG_CONFIG_HOME/baton/env.
                   Triggered by ANY of:
                     --target <dir>                   (most explicit)
                     --checkpoint-dir <non-default>
                     $BATON_DIR exported in the environment

CAVEAT: If $BATON_DIR is exported from an old/unrelated install, full
mode will rewrite that path's .gitignore even when run from $PWD elsewhere.
Unset BATON_DIR before running, or pass --target explicitly.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --settings)        SETTINGS="$2"; shift 2 ;;
    --checkpoint-dir)  BATON_DIR_ARG="$2"; shift 2 ;;
    --target)          TARGET_ARG="$2"; shift 2 ;;
    --no-archive)      ARCHIVE=0; shift ;;
    --help|-h)         _print_usage; exit 0 ;;
    *)                 _print_usage >&2; exit 2 ;;
  esac
done

if [ -z "$SETTINGS" ]; then
  SETTINGS="$HOME/.claude/settings.json"
fi
if [ -z "$BATON_DIR_ARG" ]; then
  BATON_DIR_ARG="${BATON_DIR:-$PWD/.baton}"
fi
# An explicit signal for "this is the project root being uninstalled" - derived
# from --target, --checkpoint-dir, or $BATON_DIR env. Without it we run a
# soft uninstall (hooks only) so accidental `uninstall` from $PWD does not
# rewrite an unrelated repo's .gitignore or remove a developer's actual cron
# wrapper from $REPO_DIR/tools/cleanup-cron-wrapper.sh.
TARGET_EXPLICIT=""
if [ -n "$TARGET_ARG" ]; then
  TARGET_EXPLICIT="$TARGET_ARG"
elif [ -n "${BATON_DIR:-}" ]; then
  TARGET_EXPLICIT="$(dirname "$BATON_DIR")"
elif [ -n "$BATON_DIR_ARG" ] && [ "$BATON_DIR_ARG" != "$PWD/.baton" ]; then
  # --checkpoint-dir passed explicitly (anything except the $PWD default).
  TARGET_EXPLICIT="$(dirname "$BATON_DIR_ARG")"
fi

# 1. Strip hook entries.
if [ -f "$SETTINGS" ]; then
  bash "$REPO_DIR/tools/merge-settings.sh" --remove "$SETTINGS"
  echo "OK: removed checkpoint hooks from $SETTINGS"

  # Strip the hooks install.sh registers via inline jq blocks
  # (post-tool-batch + tool-timing + post-subagent-cost). Mirrors install.sh
  # by command path so the user's settings.json is the same before/after.
  _ptb_cmd="bash $REPO_DIR/.claude/hooks/post-tool-batch.sh"
  _tt_cmd="bash $REPO_DIR/.claude/hooks/tool-timing.sh"
  _ssc_cmd="bash $REPO_DIR/.claude/hooks/post-subagent-cost.sh"
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
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  unset _ptb_cmd _tt_cmd _ssc_cmd
fi

# 2. Strip install-time artifacts (inverse of install steps 6, 7).
# Only run when the target was supplied explicitly - otherwise this is a soft
# uninstall and we deliberately leave file-system side effects in place.
if [ -n "$TARGET_EXPLICIT" ]; then
  # 2a. Remove .baton/ entry from project .gitignore.
  GITIGNORE="$TARGET_EXPLICIT/.gitignore"
  if [ -f "$GITIGNORE" ] && grep -qE '^\.baton/?$' "$GITIGNORE"; then
    _gi_tmp=$(mktemp "${GITIGNORE}.XXXXXX")
    grep -vE '^\.baton/?$' "$GITIGNORE" > "$_gi_tmp" && mv "$_gi_tmp" "$GITIGNORE"
    echo "OK: removed .baton/ entry from $GITIGNORE"
  fi
  unset _gi_tmp GITIGNORE

  # 2b. Remove cron wrapper + env file (mirrors install-cron.sh exact paths).
  CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
  ENV_FILE="$CONFIG_HOME/baton/env"
  WRAPPER="$REPO_DIR/tools/cleanup-cron-wrapper.sh"
  if [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
    rmdir "$(dirname "$ENV_FILE")" 2>/dev/null || true
    echo "OK: removed $ENV_FILE"
  fi
  if [ -f "$WRAPPER" ]; then
    rm -f "$WRAPPER"
    echo "OK: removed $WRAPPER"
  fi
  unset CONFIG_HOME ENV_FILE WRAPPER

  # 2c. Remove project-local skills copied by install step 4b.
  SKILLS_DIR="$TARGET_EXPLICIT/.claude/skills"
  for _skill in baton install-baton; do
    if [ -e "$SKILLS_DIR/$_skill" ]; then
      rm -rf "${SKILLS_DIR:?}/$_skill"
      echo "OK: removed skill $_skill from $SKILLS_DIR"
    fi
  done
  unset _skill SKILLS_DIR
fi

# 3. Archive checkpoint dir.
if [ "$ARCHIVE" = "1" ] && [ -d "$BATON_DIR_ARG" ]; then
  ARCHIVE_ROOT="${BATON_ARCHIVE_DIR:-$HOME/.local/share/baton}"
  TS=$(date +%Y%m%d-%H%M%S)
  DEST="$ARCHIVE_ROOT/uninstall-$TS"
  mkdir -p "$ARCHIVE_ROOT"
  mv "$BATON_DIR_ARG" "$DEST"
  echo "OK: archived $BATON_DIR_ARG → $DEST"
fi

# 4. Crontab snippet to remove.
echo ""
echo "=== Manual step: remove this line from your crontab (run \`crontab -e\`) ==="
echo "$BATON_CRON_SCHEDULE $REPO_DIR/tools/cleanup-cron-wrapper.sh >> ..."
echo "=== End ==="
