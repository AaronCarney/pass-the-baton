#!/bin/bash
# project-context.sh - resolver for role→file mapping used by Key Files manifest rendering.
# Per design §5.5 P1-P4.
#
# Functions:
#   pc::load_config <project_dir>   - reads .baton-project/project-context.json; empty config if absent.
#   pc::resolve_role <project_dir> <role> - absolute path for a role, honoring fallback_strategy.
#   pc::render_manifest <project_dir> <template_id> - Key Files manifest markdown rows.

set -u

# Convention fallback paths per role (P3 convention list).
declare -A _PC_CONVENTION=(
  [prd]="docs/PRD.md"
  [brd]="docs/BRD.md"
  [architecture]="docs/ARCHITECTURE.md"
  [decisions]="docs/decisions.md"
  # no built-in convention (avoids baking a framework path in); configure via the standards role
  [standards]=""
  [current_plan]=""
)

# Read-if hints per role. One hint per role; not user-configurable.
declare -A _PC_HINTS=(
  [prd]="you need product intent or out-of-scope clarifications"
  [brd]="you need business-requirements context"
  [architecture]="your change touches module boundaries or interfaces"
  [decisions]="your change inherits a prior architectural choice"
  [standards]="you need workflow / coding standards"
  [current_plan]="you need tactical step-by-step for the active L2 plan"
)

# Display labels per role.
declare -A _PC_LABELS=(
  [prd]="PRD"
  [brd]="BRD"
  [architecture]="Architecture"
  [decisions]="Decisions"
  [standards]="Standards"
  [current_plan]="Current Plan"
)

pc::load_config() {
  local project_dir="$1"
  # Check global config for an overridden project_context_file path.
  local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
  local main_cfg="$cfg_root/baton/config.json"
  local override_path=""
  if [ -f "$main_cfg" ]; then
    override_path=$(jq -r '.project_context_file // empty' "$main_cfg" 2>/dev/null)
  fi
  local cfg
  if [ -n "$override_path" ]; then
    # Resolve relative to project_dir if not absolute.
    case "$override_path" in
      /*) cfg="$override_path" ;;
      *)  cfg="$project_dir/$override_path" ;;
    esac
  else
    cfg="$project_dir/.baton-project/project-context.json"
  fi
  if [ -f "$cfg" ]; then
    cat "$cfg"
  else
    echo '{}'
  fi
}

pc::resolve_role() {
  local project_dir="$1"
  local role="$2"
  local cfg; cfg=$(pc::load_config "$project_dir")
  local strategy; strategy=$(echo "$cfg" | jq -r '.fallback_strategy // "convention"')
  local configured; configured=$(echo "$cfg" | jq -r --arg r "$role" '.roles[$r] // empty')

  if [ -n "$configured" ]; then
    # Configured path - return absolute path if file exists
    local abs="$project_dir/$configured"
    [ -f "$abs" ] && echo "$abs"
    return 0
  fi

  if [ "$strategy" = "explicit" ]; then
    # No configured value + explicit mode = no resolution
    return 0
  fi

  # Convention fallback
  local conv="${_PC_CONVENTION[$role]:-}"
  [ -z "$conv" ] && return 0
  local abs="$project_dir/$conv"
  [ -f "$abs" ] && echo "$abs"
}

pc::render_manifest() {
  local project_dir="$1"
  local template_id="$2"  # reserved for per-template manifest variants
  local role
  for role in prd brd architecture decisions standards current_plan; do
    local path; path=$(pc::resolve_role "$project_dir" "$role")
    [ -z "$path" ] && continue
    [ -f "$path" ] || continue
    local label="${_PC_LABELS[$role]}"
    local hint="${_PC_HINTS[$role]}"
    # Render path relative to project_dir for readability
    local rel="${path#$project_dir/}"
    printf -- "- **%s** - \`%s\` - read if %s\n" "$label" "$rel" "$hint"
  done
}
