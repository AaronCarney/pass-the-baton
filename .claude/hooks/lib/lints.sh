#!/bin/bash
# lints.sh - write-time validation pipeline for progress files.
# Each lint function returns 0 on pass, non-zero on fail, and writes a
# bad-faith-resistant error message to stderr on fail (per V5: name the
# underlying property, not the lint field name).

set -u

# V8 - placeholder-survivor regex. Rejects any rendered progress file that still
# contains an unfilled <<UPPER_CASE>> placeholder in BODY content.
#
# HTML comment blocks (<!-- ... -->) are stripped before the match so that
# instructional comments in templates can legitimately reference the placeholder
# syntax (e.g. "<<UPPER_CASE>> - gets substituted at write time") without
# false-positiving when the model copies the comment forward. Multi-line
# comments are handled. Edge case: an inline comment that shares its line with
# body content is treated as fully stripped (deleted line); keep instructional
# comments on their own lines.
lint::v8() {
  local progress_file="$1"
  local manifest_file="$2"
  local pattern; pattern=$(jq -r '.lints.V8.pattern // "<<[A-Z_]+>>"' "$manifest_file")
  local stripped; stripped=$(sed '/<!--/,/-->/d' "$progress_file")
  local matches; matches=$(printf '%s\n' "$stripped" | grep -oE "$pattern" 2>/dev/null | sort -u)
  if [ -n "$matches" ]; then
    cat >&2 <<EOF
V8 lint failure: the progress file still contains unfilled placeholder tokens:
$matches

Each <<UPPER_CASE>> token must be replaced with an actual value before the write completes. For sections that have no content (e.g., empty Constraints/Blockers), write a literal value such as "None" rather than leaving the placeholder. The rendered progress file should contain no <<...>> tokens.
EOF
    return 1
  fi
  return 0
}

# V1 - Session Directive verbatim. Line-diffs the directive block in the
# progress file against the directive block in the active template.
lint::v1() {
  local progress_file="$1"
  local template_file="$2"
  local progress_directive; progress_directive=$(awk '/^## Session Directive$/{flag=1; next} /^## /{flag=0} flag' "$progress_file")
  local template_directive; template_directive=$(awk '/^## Session Directive$/{flag=1; next} /^## /{flag=0} flag' "$template_file")
  if [ "$progress_directive" != "$template_directive" ]; then
    cat >&2 <<EOF
V1 lint failure: the Session Directive block in the progress file does not match the active template's directive verbatim.

The directive must be copied forward without modification - no paraphrasing, no summarizing, no re-scoping. Re-read the template's Session Directive section and copy it byte-for-byte into the progress file. If you intended to update the directive, do so by editing the template (and bumping template_version), not the progress file.
EOF
    return 1
  fi
  return 0
}

# V7 - structural content lints. Runs each enabled sub-lint declared in the
# manifest. Returns non-zero on first failure.
# Envelope semantics (M4): if template_id/template_version fields are ABSENT
# from the Task State JSON block, treat as v1/factory (accept). Only fail when
# the fields are PRESENT-but-malformed.
lint::v7() {
  local progress_file="$1"
  local manifest_file="$2"
  local enabled; enabled=$(jq -r '.lints.V7.enabled // false' "$manifest_file")
  [ "$enabled" = "true" ] || return 0
  local sub_keys
  mapfile -t sub_keys < <(jq -r '.lints.V7.sub_lints | keys[]' "$manifest_file" 2>/dev/null)
  local key
  for key in "${sub_keys[@]}"; do
    case "$key" in
      whats_next_file_ref)
        local section pattern min_matches
        section=$(jq -r '.lints.V7.sub_lints.whats_next_file_ref.section' "$manifest_file")
        pattern=$(jq -r '.lints.V7.sub_lints.whats_next_file_ref.pattern' "$manifest_file")
        min_matches=$(jq -r '.lints.V7.sub_lints.whats_next_file_ref.min_matches' "$manifest_file")
        local section_body; section_body=$(awk -v s="$section" 'BEGIN{flag=0} $0 ~ "^## "s"$" {flag=1; next} /^## /{flag=0} flag' "$progress_file")
        local count; count=$(echo "$section_body" | grep -cE "$pattern" 2>/dev/null || true)
        count=${count:-0}
        min_matches=${min_matches:-1}
        if [ "${count}" -lt "${min_matches}" ] 2>/dev/null || { ! [[ "$count" =~ ^[0-9]+$ ]]; }; then
          cat >&2 <<EOF
V7 lint failure: the What's Next section must reference at least one specific file:line so the next session has a concrete starting point. Vague summary language ("continue the refactor", "finish the feature") is not sufficient. Re-write the section to name the file you would open and the line or function you would edit.
EOF
          return 1
        fi
        ;;
      position_branch_head)
        local section; section=$(jq -r '.lints.V7.sub_lints.position_branch_head.section' "$manifest_file")
        local required_patterns
        mapfile -t required_patterns < <(jq -r '.lints.V7.sub_lints.position_branch_head.required_patterns[]' "$manifest_file")
        local section_body; section_body=$(awk -v s="$section" 'BEGIN{flag=0} $0 ~ "^## "s"$" {flag=1; next} /^## /{flag=0} flag' "$progress_file")
        local p
        for p in "${required_patterns[@]}"; do
          if ! echo "$section_body" | grep -qE "$p"; then
            cat >&2 <<EOF
V7 lint failure: the Position section must include the current branch and HEAD commit so the next session can verify it's resuming on the expected git state. Add \`- Branch: <name>\` and \`- HEAD: <sha>\` lines.
EOF
            return 1
          fi
        done
        ;;
      task_state_json_entry_shape)
        local json_block; json_block=$(awk '/^## Task State$/{flag=1; next} /^## /{flag=0} flag' "$progress_file" | awk '/^```json$/{flag=1; next} /^```$/{flag=0} flag')
        if [ -z "$json_block" ]; then
          cat >&2 <<EOF
V7 lint failure: the Task State section must contain a fenced JSON block carrying the tasks_done / tasks_remaining arrays. The block was not found or is empty.
EOF
          return 1
        fi
        # Validate envelope. Absent fields → v1/factory default (accept).
        # Only fail when fields are PRESENT-but-malformed.
        local tid_raw tv_raw
        tid_raw=$(echo "$json_block" | jq -r 'has("template_id") | tostring' 2>/dev/null)
        tv_raw=$(echo "$json_block" | jq -r 'has("template_version") | tostring' 2>/dev/null)
        if [ "$tid_raw" = "true" ]; then
          local tid; tid=$(echo "$json_block" | jq -r '.template_id' 2>/dev/null)
          case "$tid" in
            free|task|factory) ;;
            *) cat >&2 <<EOF
V7 lint failure: Task State JSON envelope template_id has an unknown value '$tid'. Expected one of: free, task, factory (or omit the field entirely to use the v1 default).
EOF
               return 1 ;;
          esac
        fi
        if [ "$tv_raw" = "true" ]; then
          local tv; tv=$(echo "$json_block" | jq -r '.template_version' 2>/dev/null)
          if ! [[ "$tv" =~ ^[0-9]+$ ]]; then
            cat >&2 <<EOF
V7 lint failure: Task State JSON envelope template_version must be a non-negative integer (got '$tv'). Omit the field to use the v1 default.
EOF
            return 1
          fi
        fi
        local td_min tr_min
        td_min=$(jq -r '.lints.V7.sub_lints.task_state_json_entry_shape.tasks_done_description_min_chars // 20' "$manifest_file")
        tr_min=$(jq -r '.lints.V7.sub_lints.task_state_json_entry_shape.tasks_remaining_description_min_chars // 20' "$manifest_file")
        local bad_entries; bad_entries=$(echo "$json_block" | jq -r --argjson m "$td_min" '.tasks_done[] | select(.id == null or .description == null or (.description | length) < $m) | .id // "<no-id>"' 2>/dev/null)
        if [ -n "$bad_entries" ]; then
          cat >&2 <<EOF
V7 lint failure: each tasks_done entry must include an id and a description of at least ${td_min} characters so the next session can tell at a glance what was actually done. Short or missing descriptions: $bad_entries.
EOF
          return 1
        fi
        local bad_remaining; bad_remaining=$(echo "$json_block" | jq -r --argjson m "$tr_min" '.tasks_remaining[] | select(.id == null or .description == null or (.description | length) < $m) | .id // "<no-id>"' 2>/dev/null)
        if [ -n "$bad_remaining" ]; then
          cat >&2 <<EOF
V7 lint failure: each tasks_remaining entry must include an id and a description of at least ${tr_min} characters. Short or missing descriptions: $bad_remaining.
EOF
          return 1
        fi
        ;;
    esac
  done
  return 0
}
