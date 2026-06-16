#!/bin/bash
# template-render.sh - substitutes HOOK-FILLED placeholders in a template,
# leaving MODEL-AUTHORED placeholders intact for the model to fill at write time.
#
# Usage:
#   tpl::render_progress_file <template_path> <workstream_id> [project_dir]
#
# Echoes the rendered template to stdout. Caller is responsible for writing to disk if needed.

set -u

_RENDER_DIR="${BASH_SOURCE[0]%/*}"
if [ -f "$_RENDER_DIR/project-context.sh" ]; then
  # shellcheck disable=SC1090
  source "$_RENDER_DIR/project-context.sh"
fi
[ "${WORKSTREAM_LIB_LOADED:-}" = "1" ] || source "$_RENDER_DIR/workstream-lib.sh"

# Hook-filled placeholders. Model-authored placeholders are NOT in this list
# and are deliberately left in place.
# ARCHIVED_CHECKBOXES is HOOK-FILLED (not model-authored): on first checkpoint it
# renders as the literal "None yet", on subsequent checkpoints it copies the prior
# file's ## Archived section body. This way V8 never sees an unfilled <<ARCHIVED_CHECKBOXES>>
# token on the model-written file.
_RENDER_HOOK_FILLED=(
  BRANCH HEAD_SHA WORKSPACE_PATH GIT_LOG GIT_STATUS
  WORKSTREAM_ID DISPLAY_NAME PHASE
  L1_PLAN_PATH L1_EPOCH L1_EXIT_GATE
  L2_PLAN_PATH L2_CURRENT_STEP
  KEY_FILES_MANIFEST
  ARCHIVED_CHECKBOXES
)

tpl::render_progress_file() {
  local template_path="$1"
  local workstream_id="$2"
  local project_dir="${3:-$PWD}"

  [ -f "$template_path" ] || { echo "template-render: template not found: $template_path" >&2; return 1; }

  local content; content=$(<"$template_path")

  # Workstream record lookups.
  local ws_file="$(checkpoint_dir "$project_dir")/workstreams/${workstream_id}.json"
  local display_name="" phase="" l1_epoch="" l1_exit_gate="" l1_plan_path="" l2_plan_path="" l2_current_step=""
  if [ -f "$ws_file" ]; then
    display_name=$(jq -r '.display_name // empty' "$ws_file" 2>/dev/null)
    phase=$(jq -r '.phase // empty' "$ws_file" 2>/dev/null)
    l1_epoch=$(jq -r '.l1_epoch // empty' "$ws_file" 2>/dev/null)
    l1_exit_gate=$(jq -r '.l1_exit_gate // empty' "$ws_file" 2>/dev/null)
    l1_plan_path=$(jq -r '.l1_plan_path // empty' "$ws_file" 2>/dev/null)
    l2_plan_path=$(jq -r '.l2_plan_path // empty' "$ws_file" 2>/dev/null)
    l2_current_step=$(jq -r '.l2_current_step // empty' "$ws_file" 2>/dev/null)
  fi

  # Git lookups (only if project_dir is a git repo).
  local branch="" head_sha="" git_log="" git_status=""
  if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    head_sha=$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null)
    git_log=$(git -C "$project_dir" log --oneline -10 2>/dev/null)
    git_status=$(git -C "$project_dir" status -s 2>/dev/null)
  fi

  # Key Files manifest via project-context resolver (if available).
  local key_files=""
  if declare -F pc::render_manifest >/dev/null; then
    key_files=$(pc::render_manifest "$project_dir" factory 2>/dev/null)
  fi

  # Archived checkboxes - HOOK-FILLED. Read prior file's ## Archived section body and use it,
  # else fall back to "None yet" so V8 never sees an unfilled <<ARCHIVED_CHECKBOXES>> token.
  # ROLLOFF_PRIOR_PROGRESS is set by the write-trigger (Task 8) to the most-recent archived
  # progress file before this render.
  local archived_body="None yet"
  local prior_progress="${ROLLOFF_PRIOR_PROGRESS:-}"
  if [ -n "$prior_progress" ] && [ -f "$prior_progress" ]; then
    local body; body=$(awk '/^## Archived$/{flag=1; next} /^## /{flag=0} flag' "$prior_progress" | sed -e '/^$/d' -e '/^None yet$/d')
    [ -n "$body" ] && archived_body="$body"
  fi

  # Substitute. Use awk for multiline-safe substitution.
  _render_sub() {
    local key="$1" value="$2"
    content=$(awk -v k="<<${key}>>" -v v="$value" '
      {
        while ((i = index($0, k)) > 0) {
          $0 = substr($0, 1, i-1) v substr($0, i+length(k))
        }
        print
      }
    ' <<<"$content")
  }

  _render_sub BRANCH "$branch"
  _render_sub HEAD_SHA "$head_sha"
  _render_sub WORKSPACE_PATH "$project_dir"
  _render_sub GIT_LOG "$git_log"
  _render_sub GIT_STATUS "$git_status"
  _render_sub WORKSTREAM_ID "$workstream_id"
  _render_sub DISPLAY_NAME "$display_name"
  _render_sub PHASE "$phase"
  _render_sub L1_PLAN_PATH "$l1_plan_path"
  _render_sub L1_EPOCH "$l1_epoch"
  _render_sub L1_EXIT_GATE "$l1_exit_gate"
  _render_sub L2_PLAN_PATH "$l2_plan_path"
  _render_sub L2_CURRENT_STEP "$l2_current_step"
  _render_sub KEY_FILES_MANIFEST "$key_files"
  _render_sub ARCHIVED_CHECKBOXES "$archived_body"

  printf '%s\n' "$content"
}
