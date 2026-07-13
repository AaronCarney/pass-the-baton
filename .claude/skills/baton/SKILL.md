---
name: baton
description: View or change Pass the Baton configuration. Use for template switching, threshold adjustment, or inspecting current config.
---

# /baton - Configuration Dashboard

When installed as a plugin the command is namespaced: `/pass-the-baton:baton`. The bare `/baton` form is available only via the manual `install.sh` project-local install.

## When to Use

- See the current Pass the Baton config (`/baton` or `/baton show`)
- Change a config value (`/baton set key=value`)
- Switch progress-file template (`/baton set template=factory`)

## Process

### Show mode (default)

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/tools/baton-dashboard.sh" show
```

Prints current global keys + active template's `template_version`. Does not modify anything.

### Set mode

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/tools/baton-dashboard.sh" set <key>=<value> [<key2>=<value2> ...]
```

Valid keys. `show` lists them grouped by category, and reads each with
env-var > config.json > default precedence (`lib/config.sh`).

**[Existing]**

| Key | Validation | Example |
|---|---|---|
| `template` | One of: `free`, `task`, `factory`, or a custom template installed at `$XDG_CONFIG_HOME/baton/templates/<name>.md` | `template=factory` |
| `threshold_pct` | Integer 1-99 | `threshold_pct=35` |
| `display_name` | Free-form string | `display_name=myproject` |
| `templates_dir` | Free-form path | `templates_dir=/path/to/templates` |
| `project_context_file` | Path relative to project root | `project_context_file=.baton-project/project-context.json` |

**[Paths]** - non-empty string

| Key | Validation | Example |
|---|---|---|
| `BATON_DIR` | Non-empty path | `BATON_DIR=/srv/.baton` |
| `BATON_PROGRESS_DIR` | Non-empty path | `BATON_PROGRESS_DIR=/srv/.baton/progress` |
| `BATON_ARCHIVE_DIR` | Non-empty path | `BATON_ARCHIVE_DIR=~/.local/share/baton` |
| `BATON_PROJECT_DIR` | Non-empty path | `BATON_PROJECT_DIR=/srv/repo` |

**[TTLs]** - non-negative integer (regex `^[0-9]+$`; NOT trimmed - ` 14` is rejected)

| Key | Validation | Example |
|---|---|---|
| `BATON_WORKSTREAM_TTL_DAYS` | Integer ≥0 | `BATON_WORKSTREAM_TTL_DAYS=30` |
| `BATON_TRACKING_TTL_DAYS` | Integer ≥0 | `BATON_TRACKING_TTL_DAYS=90` |
| `BATON_TMP_TTL_HOURS` | Integer ≥0 | `BATON_TMP_TTL_HOURS=48` |

**[Opt-ins]** - `0` or `1`

| Key | Validation | Example |
|---|---|---|
| `BATON_TIMING` | 0 or 1 | `BATON_TIMING=1` |
| `BATON_OUTCOME_PROXIES` | 0 or 1 | `BATON_OUTCOME_PROXIES=1` |
| `BATON_PREWARM` | 0 or 1 | `BATON_PREWARM=1` |
| `BATON_EVENT_LOG_DISABLE` | 0 or 1 | `BATON_EVENT_LOG_DISABLE=1` |

**[Event-log]** - non-empty string

| Key | Validation | Example |
|---|---|---|
| `BATON_EVENT_LOG` | Non-empty path | `BATON_EVENT_LOG=/srv/hook-events.jsonl` |
| `BATON_OTEL_EXPORT` | Non-empty string | `BATON_OTEL_EXPORT=otlp` |

**[Cost-model]**

| Key | Validation | Example |
|---|---|---|
| `BATON_COST_MODEL` | Non-empty string (resolved by cost.sh) | `BATON_COST_MODEL=claude-sonnet-4-6` |
| `BATON_SUMMARY_MODEL` | Non-empty string (resolved by cost.sh) | `BATON_SUMMARY_MODEL=claude-sonnet-4-6` |
| `BATON_TOKEN_RATIOS` | Non-empty string (`=` preserved in value) | `BATON_TOKEN_RATIOS=input=3,output=15` |

**[Statusline]**

| Key | Validation | Example |
|---|---|---|
| `BATON_STATUSLINE_COLOR_MODE` | One of: `off`, `solid`, `bands` | `BATON_STATUSLINE_COLOR_MODE=bands` |

On validation failure, the driver prints an error to stderr and exits 1 without modifying the config.

## Important

- Config file: `$XDG_CONFIG_HOME/baton/config.json` (or `~/.config/baton/config.json` if XDG unset)
- Atomic writes under flock
- Template switch is refused while a checkpoint is in flight (PENDING flag set) - retry after the progress file is written
- The PENDING check (`/tmp/baton-pending-*`) matches any Claude Code session on the host, not just the current one. Template switch is refused while ANY Claude Code session on this host has a pending checkpoint. This is intentionally conservative - wait for the in-flight checkpoint to clear (typically a single `Write` away).
- The shipped templates (`free`, `task`, `factory`) are always available; custom templates require installation first per `share/templates/README.md`
