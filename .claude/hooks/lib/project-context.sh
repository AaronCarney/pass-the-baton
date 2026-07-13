#!/bin/bash
# project-context.sh - registry-driven resolver for role->file mapping used by the
# Key Files manifest. Per design E (E7): roles come from an in-code default seed
# MERGED with the user's project-context.json registry, so a user-defined role
# surfaces as an injected Key Files pointer with NO code edit.
#
# Functions:
#   pc::load_config <project_dir>   - reads .baton-project/project-context.json; '{}' if absent.
#   pc::resolve_role <project_dir> <role> - absolute path for a role, honoring fallback_strategy.
#   pc::render_manifest <project_dir> <template_id> - Key Files manifest markdown rows.

set -u

# Default seed for the six built-in roles: display label, read-if hint, convention
# fallback path (used only under fallback_strategy=convention), and default order.
# The user registry in project-context.json MERGES over this (override a built-in
# by naming it; append a brand-new role by adding a new key) - no code edit needed.
_PC_SEED='{
  "prd":          {"label":"PRD",          "hint":"you need product intent or out-of-scope clarifications", "convention":"docs/PRD.md",          "order":10},
  "brd":          {"label":"BRD",          "hint":"you need business-requirements context",                  "convention":"docs/BRD.md",          "order":20},
  "architecture": {"label":"Architecture", "hint":"your change touches module boundaries or interfaces",     "convention":"docs/ARCHITECTURE.md", "order":30},
  "decisions":    {"label":"Decisions",    "hint":"your change inherits a prior architectural choice",        "convention":"docs/decisions.md",    "order":40},
  "standards":    {"label":"Standards",    "hint":"you need workflow / coding standards",                     "convention":"",                     "order":50},
  "current_plan": {"label":"Current Plan", "hint":"you need tactical step-by-step for the active L2 plan",     "convention":"",                     "order":60}
}'

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
    local norm
    if norm=$(jq -c 'if type=="object" then . else empty end' "$cfg" 2>/dev/null) && [ -n "$norm" ]; then
      printf '%s\n' "$norm"
      return 0
    fi
  fi
  echo '{}'
}

# Merge the in-code seed with the config's `roles` map into a single ordered
# registry array: [{role,label,hint,path,convention,order}, ...] sorted by order.
# A user role value may be a bare STRING (path override - backward-compat with the
# pre-E7 roles-as-pathmap schema) or an OBJECT carrying any of label/hint/path/
# convention/order. Built-ins keep their seed order; brand-new user roles append
# (order 1000 + insertion-index) unless they set an explicit `order`.
pc::_registry() {
  local cfg="$1"
  jq -n --argjson seed "$_PC_SEED" --argjson cfg "$cfg" '
    ($cfg.roles // {}) as $roles
    | ($roles | keys_unsorted) as $ukeys
    | ($seed | keys_unsorted) as $skeys
    | ($skeys + ($ukeys - $skeys)) as $names
    | [ $names[]
        | . as $r
        | ($seed[$r] // {}) as $s
        | ($roles[$r]) as $uv
        | (if   ($uv|type)=="string" then {path:$uv}
           elif ($uv|type)=="object" then $uv
           else {} end) as $u
        | {
            role: $r,
            label:      ($u.label      // $s.label      // ($r|gsub("_";" "))),
            hint:       ($u.hint        // $s.hint       // ""),
            path:       ($u.path        // ""),
            convention: ($u.convention  // $s.convention // ""),
            order:      ($u.order        // $s.order      // (1000 + ($ukeys|index($r) // 0)))
          }
      ]
    | sort_by(.order)
  '
}

pc::resolve_role() {
  local project_dir="$1"
  local role="$2"
  local cfg; cfg=$(pc::load_config "$project_dir")
  local strategy; strategy=$(echo "$cfg" | jq -r '.fallback_strategy // "convention"')
  local entry; entry=$(pc::_registry "$cfg" | jq -c --arg r "$role" 'map(select(.role==$r)) | .[0] // empty')
  [ -z "$entry" ] && return 0
  local path conv
  path=$(echo "$entry" | jq -r '.path')
  conv=$(echo "$entry" | jq -r '.convention')

  if [ -n "$path" ]; then
    # Explicit path override - return absolute path if the file exists.
    local abs="$project_dir/$path"
    [ -f "$abs" ] && echo "$abs"
    return 0
  fi

  if [ "$strategy" = "explicit" ]; then
    # No explicit path + explicit mode = no resolution.
    return 0
  fi

  # Convention fallback.
  [ -z "$conv" ] && return 0
  local abs="$project_dir/$conv"
  [ -f "$abs" ] && echo "$abs"
}

pc::render_manifest() {
  local project_dir="$1"
  # shellcheck disable=SC2034  # reserved for per-template manifest variants
  local template_id="$2"
  local cfg; cfg=$(pc::load_config "$project_dir")
  local reg; reg=$(pc::_registry "$cfg")
  local count; count=$(echo "$reg" | jq 'length' 2>/dev/null)
  [ -z "$count" ] && count=0
  local i=0
  while [ "$i" -lt "$count" ]; do
    local entry; entry=$(echo "$reg" | jq -c ".[$i]")
    i=$((i+1))
    local role label hint abs rel
    role=$(echo "$entry" | jq -r '.role')
    label=$(echo "$entry" | jq -r '.label')
    hint=$(echo "$entry" | jq -r '.hint')
    # Resolve via pc::resolve_role so render and resolve share ONE precedence
    # (a non-empty explicit path short-circuits convention even when its file is missing).
    abs=$(pc::resolve_role "$project_dir" "$role")
    [ -z "$abs" ] && continue
    [ -f "$abs" ] || continue
    rel="${abs#"$project_dir"/}"
    if [ -n "$hint" ]; then
      printf -- "- **%s** - \`%s\` - read if %s\n" "$label" "$rel" "$hint"
    else
      printf -- "- **%s** - \`%s\`\n" "$label" "$rel"
    fi
  done
}
