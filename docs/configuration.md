# Configuration files

This page is the map of every config surface in the project: where each file lives, who writes it, what it holds, and who reads it. For the env-var *values* themselves (full table + meaning of each knob) see [context-baton.md](context-baton.md).

## Resolution order

Every `BATON_*`-backed knob is resolved by `lib/config.sh::_cfg::get` using a single, fixed precedence:

1. **The environment variable wins.** Lookup is by indirect expansion (`${!key}`), not `printenv`, so even a *non-exported* shell var is honored.
2. **The matching key in `config.json`.** If the env var is unset/empty, the value persisted under the config key is used.
3. **The built-in default.** Used only when neither of the above yields a value.

`_cfg::set` - the write path used by the `/baton` dashboard and the tuner - writes **only** the `config.json` layer. An exported env var always overrides what `_cfg::set` persisted, since the env var is checked first.

Cited: `lib/config.sh:10-40`.

## Config-file reference

### `config.json`

- **Path:** `$XDG_CONFIG_HOME/baton/config.json` (typically `~/.config/baton/config.json`). It is **not** under `$BATON_DIR`.
- **Written by:** the `/baton` dashboard (`tools/baton-dashboard.sh set`).
- **Read by:** `_cfg::get` (the config.json layer of the resolution order above).
- **Holds:** the runtime knob store. Keys:
  - `template` - active progress template.
  - `threshold_pct` - checkpoint trigger fill, integer 1-99, default 20. Out-of-range or non-integer values are rejected by the dashboard and the trigger falls back to 20.
  - `display_name` - workstream display name.
  - `templates_dir` - override for the templates directory.
  - `project_context_file` - override for the project-context file path.
  - `per_template.<name>.template_version` - per-template version map.
  - Opt-in flags (each `0`/`1`): `BATON_COLLECT`, `BATON_TIMING`, `BATON_OUTCOME_PROXIES`, `BATON_PREWARM`, `BATON_EVENT_LOG_DISABLE`.
  - Adaptive-tuner keys: `tune_setpoint`, `tune_deadband`, `tune_step`, `tune_safety_min`, `tune_safety_max`, `tune_dwell_seconds`, `tune_score_fn`. These are placeholder-valued and inert - see [context-baton.md#adaptive-threshold-tuner-built-not-yet-connected](context-baton.md#adaptive-threshold-tuner-built-not-yet-connected).

### `.baton-project/project-context.json`

- **Holds:** per-project role mapping (`{version, fallback_strategy}`).
- Full detail in [project-context.md](project-context.md).

### `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`

- The Claude Code plugin manifest.
- Intentionally carries **no** semver `version` - it is SHA-versioned. The installed revision tracks marketplace HEAD.

### `hooks/hooks.json`

- The plugin's hook-wiring manifest.
- Points the 7 hook events (`PreToolUse`, `PostToolUse`, `PostToolBatch`, `SubagentStop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`) at `${CLAUDE_PLUGIN_ROOT}/.claude/hooks/*`.

### `.claude/settings.json`

- Repo-local hook wiring for **this** repo's own dev sessions.
- Wires only the cost/latency/subagent hooks: `PostToolBatch`, `PostToolUse`, `SubagentStop`, `UserPromptSubmit`. It does **not** wire the core continuity hooks - those ship via the plugin (`hooks/hooks.json`).

### `.baton/audit-metadata.json`

- Cost-model audit bookkeeping: audit date, cost-model version, per-arm residuals, next-audit-due, and related instrument state.
- This is **internal measurement-instrument state, not a user-tunable knob.** Do not edit it to change behavior.

## Auto-continue (tmux, opt-in)

`BATON_AUTO_CONTINUE` is **off by default** and does nothing unless the session runs inside tmux. When enabled inside tmux, after a checkpoint save the tool auto-sends `/clear` and a continue nudge into the *same* tmux pane, so you do not have to hand off the next session yourself. It drives this purely through `tmux send-keys` into that pane; it does **not** use PTY/expect or `TIOCSTI`. It fires exactly once per checkpoint, never mid-write, and outside tmux it is a clean no-op.

- `BATON_AUTO_CONTINUE` (default off): set to `1` **and** run inside tmux to enable the behavior above. Any other value, or no tmux, leaves it disabled.
- `BATON_AUTO_CONTINUE_NUDGE` (default `proceed`): the text sent after `/clear` to start the next session working on the auto-injected progress.
- `BATON_AUTO_CONTINUE_LOG` (default `${TMPDIR:-/tmp}/baton-auto-continue.log`): once the injector consumes the done-flag it is committed, so every terminal state past that point writes one line here (`continued`, `cleared-not-continued-prompt-timeout`, `fail-clear-send`, and similar). Check it if an auto-continue did not behave as expected.

**Abort:** delete `/tmp/baton-done-<session_id>` during the brief readiness poll before the keys are sent. Unsetting `BATON_AUTO_CONTINUE` in the pane does **not** abort an already-spawned injector - it is a detached process with a frozen environment, so deleting the done-flag is the only mechanism that stops it.

**First use:** idle detection is a best-effort heuristic. Before relying on it, enable it once in your real terminal and confirm `/clear` fires only after a turn ends. The feature is off by default and abortable (delete the done-flag), and every committed action is logged, so a mis-fire is diagnosable.

## See also

- [context-baton.md](context-baton.md) - full env-var table + state schema.
- [project-context.md](project-context.md) - `project-context.json` role mapping.
- [cli.md#toolsbaton-dashboardsh](cli.md#toolsbaton-dashboardsh) - the dashboard CLI that writes `config.json`.
- [architecture.md](architecture.md) - where these files sit in the data flow.
