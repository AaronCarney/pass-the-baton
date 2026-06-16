#!/bin/bash
# rolloff.sh - archive-not-delete movers per Amendment 2026-05-21 N1-N4.
#
# Strategies:
#   none              - no rolloff (free.md). Function returns 0 immediately.
#   archive-checkbox  - move `[x]` items from source_section to target_section (task.md).
#   fresh-judgment    - model decides per-checkpoint what to carry; non-carried entries archive (factory.md).
#                       On L1-epoch boundary (detected via workstream record: current_epoch arg vs the
#                       previous_l1_epoch field Task 8 persists after each successful render), archive
#                       the entire prior tasks_done.
#
# Used by checkpoint-write-trigger.sh after lints pass.

set -u

_ROLLOFF_DIR="${BASH_SOURCE[0]%/*}"
[ "${WORKSTREAM_LIB_LOADED:-}" = "1" ] || source "$_ROLLOFF_DIR/workstream-lib.sh"

rolloff::_substitute_archive_path() {
  local template="$1" workstream="$2" epoch="$3"
  template="${template//\{workstream\}/$workstream}"
  template="${template//\{epoch\}/$epoch}"
  echo "$template"
}

rolloff::archive_checkbox() {
  local progress_file="$1"
  local source_section="$2"
  local target_section="$3"
  local trigger="${4:-[x]}"

  local tmp; tmp=$(mktemp)
  # Extract done items from source section
  local done_items; done_items=$(awk -v s="$source_section" -v t="$trigger" '
    BEGIN{flag=0}
    $0 ~ "^## "s"$" {flag=1; next}
    /^## /{flag=0}
    flag && index($0, t) > 0 {print}
  ' "$progress_file")
  [ -z "$done_items" ] && { rm -f "$tmp"; return 0; }

  # Build new file: drop done items from source, append to target
  awk -v s="$source_section" -v tgt="$target_section" -v t="$trigger" '
    BEGIN{in_source=0; in_target=0}
    $0 ~ "^## "s"$" {in_source=1; in_target=0; print; next}
    $0 ~ "^## "tgt"$" {in_target=1; in_source=0; print; next}
    /^## /{in_source=0; in_target=0; print; next}
    in_source && index($0, t) > 0 {next}
    in_target && /^None( yet)?$/ {next}
    {print}
  ' "$progress_file" > "$tmp"

  # Second pass: insert done_items into target section (after the section header)
  awk -v tgt="$target_section" -v done_items="$done_items" '
    BEGIN{inserted=0}
    $0 ~ "^## "tgt"$" {
      print
      print ""
      print done_items
      inserted=1
      next
    }
    {print}
  ' "$tmp" > "${tmp}.2"

  mv "${tmp}.2" "$progress_file"
  rm -f "$tmp"
}

rolloff::fresh_judgment_archive() {
  local progress_file="$1"
  local archive_dir_template="$2"
  local epoch_boundary_full_archive="$3"
  local workstream_id="$4"
  local current_epoch="$5"
  local prior_progress="${6:-}"
  local project_dir="${7:-$PWD}"

  [ -n "$prior_progress" ] && [ -f "$prior_progress" ] || return 0

  # Extract prior + current tasks_done JSON arrays.
  local prior_json; prior_json=$(awk '/^## Task State$/{flag=1; next} /^## /{flag=0} flag' "$prior_progress" | awk '/^```json$/{flag=1; next} /^```$/{flag=0} flag')
  local curr_json; curr_json=$(awk '/^## Task State$/{flag=1; next} /^## /{flag=0} flag' "$progress_file" | awk '/^```json$/{flag=1; next} /^```$/{flag=0} flag')

  # Read previous_l1_epoch from the workstream record (persisted by the write-trigger AFTER each
  # successful render - see Task 8). The R4 JSON envelope has no l1_epoch field, so the workstream
  # record is the authoritative source. previous_l1_epoch is the epoch at the time of the prior write;
  # current_epoch is the epoch now. Boundary = the two differ.
  local ws_file="$(checkpoint_dir "$project_dir")/workstreams/${workstream_id}.json"
  local prior_epoch=""
  if [ -f "$ws_file" ]; then
    prior_epoch=$(jq -r '.previous_l1_epoch // empty' "$ws_file" 2>/dev/null)
  fi
  # Detect epoch boundary: previous_l1_epoch (recorded at last write) differs from current_epoch.
  local epoch_boundary=false
  if [ "$epoch_boundary_full_archive" = "true" ] && [ -n "$prior_epoch" ] && [ "$prior_epoch" != "$current_epoch" ]; then
    epoch_boundary=true
  fi

  # Use prior epoch for archive dir on boundary, else current.
  local archive_epoch="$current_epoch"
  $epoch_boundary && archive_epoch="$prior_epoch"
  local archive_dir; archive_dir=$(rolloff::_substitute_archive_path "$archive_dir_template" "$workstream_id" "$archive_epoch")
  local full_archive_dir="$project_dir/$archive_dir"
  mkdir -p "$full_archive_dir"

  local ts; ts=$(date +%Y%m%d-%H%M%S)
  if $epoch_boundary; then
    # Archive entire prior tasks_done in one shot
    echo "$prior_json" | jq '.tasks_done // []' > "$full_archive_dir/tasks-done-epoch-${prior_epoch}-${ts}.json"
  else
    # Archive diff: entries in prior_json.tasks_done but not in curr_json.tasks_done (by id).
    # Use temp files to avoid shell quoting issues with --argjson and JSON containing special chars.
    local p_tmp c_tmp; p_tmp=$(mktemp); c_tmp=$(mktemp)
    [ -n "$prior_json" ] && echo "$prior_json" > "$p_tmp" || echo '{}' > "$p_tmp"
    [ -n "$curr_json" ] && echo "$curr_json" > "$c_tmp" || echo '{}' > "$c_tmp"
    local diff; diff=$(jq -n --slurpfile p "$p_tmp" --slurpfile c "$c_tmp" '
      ($p[0].tasks_done // []) as $prior
      | ($c[0].tasks_done // []) | map(.id) as $curr_ids
      | $prior | map(select(.id as $id | $curr_ids | index($id) | not))
    ' 2>/dev/null)
    rm -f "$p_tmp" "$c_tmp"
    if [ -n "$diff" ] && [ "$diff" != "[]" ] && [ "$diff" != "null" ]; then
      echo "$diff" > "$full_archive_dir/tasks-done-rollover-${ts}.json"
    fi
  fi
}

rolloff::dispatch() {
  local progress_file="$1"
  local manifest_file="$2"
  local workstream_id="$3"
  local project_dir="${4:-$PWD}"

  local strategy; strategy=$(jq -r '.rolloff.strategy // "none"' "$manifest_file" 2>/dev/null)

  case "$strategy" in
    none) ;;  # fall through to epoch-persist below
    archive-checkbox)
      local src tgt trig
      src=$(jq -r '.rolloff.source_section // "Task State"' "$manifest_file")
      tgt=$(jq -r '.rolloff.target_section // "Archived"' "$manifest_file")
      trig=$(jq -r '.rolloff.trigger // "[x]"' "$manifest_file")
      rolloff::archive_checkbox "$progress_file" "$src" "$tgt" "$trig"
      ;;
    fresh-judgment)
      local template; template=$(jq -r '.rolloff.archive_dir_template // ".baton/archive/{workstream}/{epoch}/"' "$manifest_file")
      local boundary; boundary=$(jq -r '.rolloff.epoch_boundary_full_archive // false' "$manifest_file")
      # Read current epoch from workstream record.
      local ws_file="$(checkpoint_dir "$project_dir")/workstreams/${workstream_id}.json"
      local current_epoch="1"
      [ -f "$ws_file" ] && current_epoch=$(jq -r '.l1_epoch // 1' "$ws_file" 2>/dev/null)
      # Prior progress: write-trigger sets ROLLOFF_PRIOR_PROGRESS to the most recent
      # archived progress file before invoking dispatch (from ARCHIVE_LIST head).
      local prior="${ROLLOFF_PRIOR_PROGRESS:-}"
      rolloff::fresh_judgment_archive "$progress_file" "$template" "$boundary" "$workstream_id" "$current_epoch" "$prior" "$project_dir"
      ;;
    *) return 0 ;;
  esac

  # Persist previous_l1_epoch = current l1_epoch on the workstream record.
  # Co-located with the epoch read site (fresh_judgment reads .previous_l1_epoch here too)
  # so the read+write live in one lib instead of split-brain between the trigger and dispatcher.
  # Applies to ALL strategies - boundary detection for the next session is useful regardless
  # of which rolloff strategy is active right now.
  local ws_file="$(checkpoint_dir "$project_dir")/workstreams/${workstream_id}.json"
  if [ -f "$ws_file" ]; then
    local current_epoch; current_epoch=$(jq -r '.l1_epoch // empty' "$ws_file" 2>/dev/null)
    if [ -n "$current_epoch" ]; then
      local tmp_ws; tmp_ws=$(mktemp)
      jq --arg e "$current_epoch" '.previous_l1_epoch = ($e | tonumber? // $e)' "$ws_file" > "$tmp_ws" && mv "$tmp_ws" "$ws_file"
    fi
  fi
}
