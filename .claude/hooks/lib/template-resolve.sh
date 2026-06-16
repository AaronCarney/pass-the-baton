#!/bin/bash
# template-resolve.sh - single source of truth for active-template path resolution.
#
# Precedence order:
#   1. BATON_TEMPLATE_PATH env var (if set and file exists) - ad-hoc override.
#   2. config.json `templates_dir` + `template` id (if both set and file exists).
#   3. $PROJECT_DIR/share/templates/<template-id>.md (when the OSS repo IS the project).
#   4. <hook-lib-repo>/share/templates/<template-id>.md (symlinked-consumer pattern:
#      checkpoint hooks live in a sibling/symlinked repo that a consumer workspace
#      sources from. The lib's own location identifies its shipped templates
#      regardless of where $PROJECT_DIR points.
#   5. <hook-lib-repo>/share/templates/free.md (ultimate fallback).
#
# Used by both context-checkpoint.sh and checkpoint-write-trigger.sh to avoid drift.

set -u

tpl::resolve_active_template() {
  local project_dir="$1"

  # 1. Env var
  if [ -n "${BATON_TEMPLATE_PATH:-}" ] && [ -f "$BATON_TEMPLATE_PATH" ]; then
    echo "$BATON_TEMPLATE_PATH"
    return 0
  fi

  # 2. Config custom templates_dir
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/baton/config.json"
  local template_id="free"
  if [ -f "$cfg" ]; then
    template_id=$(jq -r '.template // "free"' "$cfg" 2>/dev/null)
    local custom_dir; custom_dir=$(jq -r '.templates_dir // empty' "$cfg" 2>/dev/null)
    if [ -n "$custom_dir" ] && [ -f "$custom_dir/${template_id}.md" ]; then
      echo "$custom_dir/${template_id}.md"
      return 0
    fi
  fi

  # 3. project_dir/share/templates (OSS repo is the project)
  if [ -f "$project_dir/share/templates/${template_id}.md" ]; then
    echo "$project_dir/share/templates/${template_id}.md"
    return 0
  fi

  # 4. Hook lib's own repo share/templates (symlinked-consumer fallback). The lib
  #    lives at <repo>/.claude/hooks/lib/template-resolve.sh, so the repo root is
  #    three levels up.
  local lib_repo; lib_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  if [ -f "$lib_repo/share/templates/${template_id}.md" ]; then
    echo "$lib_repo/share/templates/${template_id}.md"
    return 0
  fi

  # 5. Ultimate fallback (lib's repo, not project_dir - project_dir may have no share/)
  echo "$lib_repo/share/templates/free.md"
}
