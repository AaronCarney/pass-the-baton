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
- Carries a semver `version`; the release history is recorded in [`CHANGELOG.md`](../CHANGELOG.md). The installed revision tracks the marketplace repo.

### `hooks/hooks.json`

- The plugin's hook-wiring manifest.
- Points the 8 hook events (`PreToolUse`, `PostToolUse`, `PostToolBatch`, `SubagentStop`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`) at `${CLAUDE_PLUGIN_ROOT}/.claude/hooks/*`.

### `.claude/settings.json`

- Repo-local hook wiring for **this** repo's own dev sessions.
- Wires only the cost/latency/subagent hooks: `PostToolBatch`, `PostToolUse`, `SubagentStop`, `UserPromptSubmit`. It does **not** wire the core continuity hooks - those ship via the plugin (`hooks/hooks.json`).

### `.baton/audit-metadata.json`

- Cost-model audit bookkeeping: audit date, cost-model version, per-arm residuals, next-audit-due, and related instrument state.
- This is **internal measurement-instrument state, not a user-tunable knob.** Do not edit it to change behavior.

## Auto-continue (opt-in)

Auto-continue is **off by default**. When you turn it on, a checkpoint save hands off to the next session for you instead of leaving you to do it by hand. Two drivers do that, and they are **options, not a progression** - neither is recommended over the other, and neither is the default. Pick the one that fits how you already work.

| Mode | Needs | How it continues |
|---|---|---|
| `tmux` | the session running inside tmux | sends `/clear` + a nudge into the *same* pane; the session keeps running |
| `relaunch` | launching via `tools/baton-run.sh` instead of `claude` | the session exits at turn end and a fresh `claude` starts in the same terminal |

`BATON_AUTO_CONTINUE_MODE` (default `off`) selects the driver: `off`, `tmux`, or `relaunch`. Set it in the environment, or persist it with `tools/baton-dashboard.sh set auto_continue_mode=relaunch`. An unrecognized value resolves to `off` - a typo must never arm a driver.

**`BATON_AUTO_CONTINUE=1` still means tmux.** If you set it and leave `BATON_AUTO_CONTINUE_MODE` unset, you get exactly the tmux behavior you had before, unchanged. The legacy flag acts as a *default*, consulted only when no mode is set at any layer - so an explicit mode (env or `config.json`) wins over it.

Cited: `lib/config.sh:65-73`.

### tmux driver

When enabled inside tmux, after a checkpoint save the tool auto-sends `/clear` and a continue nudge into the *same* tmux pane, so you do not have to hand off the next session yourself. It drives this purely through `tmux send-keys` into that pane; it does **not** use PTY/expect or `TIOCSTI`. It fires exactly once per checkpoint, never mid-write, and outside tmux it is a clean no-op.

- `BATON_AUTO_CONTINUE` (default off): set to `1` **and** run inside tmux to enable the behavior above. Any other value, or no tmux, leaves it disabled.
- `BATON_AUTO_CONTINUE_NUDGE` (default `proceed`): the text sent after `/clear` to start the next session working on the auto-injected progress.
- `BATON_AUTO_CONTINUE_LOG` (default `${TMPDIR:-/tmp}/baton-auto-continue.log`): once the injector consumes the done-flag it is committed, so every terminal state past that point writes one line here (`continued`, `cleared-not-continued-prompt-timeout`, `fail-clear-send`, and similar). Check it if an auto-continue did not behave as expected.

**Abort:** delete `/tmp/baton-done-<session_id>` during the brief readiness poll before the keys are sent. Unsetting `BATON_AUTO_CONTINUE` in the pane does **not** abort an already-spawned injector - it is a detached process with a frozen environment, so deleting the done-flag is the only mechanism that stops it.

**First use:** idle detection is a best-effort heuristic. Before relying on it, enable it once in your real terminal and confirm `/clear` fires only after a turn ends. The feature is off by default and abortable (delete the done-flag), and every committed action is logged, so a mis-fire is diagnosable.

### Fresh-relaunch driver

Launch `bash tools/baton-run.sh` **instead of** `claude` - any arguments pass straight through - and set `BATON_AUTO_CONTINUE_MODE=relaunch`. After a checkpoint save the session ends at the turn boundary and a fresh `claude` starts in the same terminal, where SessionStart re-injects the progress file. That is a clear-and-continue with no tmux and no keystroke injection.

**Why a wrapper?** No hook can end a session from the inside, so something outside the session has to start the next one. `baton-run.sh` is that supervisor: it runs `claude` in the foreground and relaunches only when the helper leaves a marker saying it ended the session *for* a relaunch. Quit normally and there is no marker, so the loop ends - that is the ordinary way out.

- `BATON_AUTO_CONTINUE_MODE` (default `off`): set to `relaunch` for this driver. See the mode selector above.
- `BATON_RELAUNCH_MAX` (default `10`): cap on relaunches per `baton-run` invocation. On reaching it the supervisor stops and says so; run `baton-run` again to keep going. A non-numeric value falls back to `10` rather than uncapping.
- `BATON_RELAUNCH_LOG` (default `${TMPDIR:-/tmp}/baton-relaunch.log`): once a relaunch is armed it is committed, so every terminal state past that point writes one line here (`armed`, `relaunch-requested`, `degraded-sigkill`, and the `noop-*` / `fail-*` tags). Check it if a relaunch did not behave as expected.

**`baton` launch alias.** So you can type `baton` instead of `bash tools/baton-run.sh`, the installer's 6th prompt (opt-in, default no) and the `/baton set launch_alias=<name>` dashboard key write a marker-guarded `alias <name>='bash <pass-the-baton-repo>/tools/baton-run.sh'` block to your shell rc (`~/.bashrc` and/or `~/.zshrc`). The alias launches Claude with your configured auto-continue driver (`off`, `tmux`, or `relaunch`), selected via `/baton set auto_continue_mode=...`; the installer seeds `relaunch` as the default only when no driver is already set. The block is rewritten in place on change and never duplicated. `launch_alias` rejects an empty name, a name with spaces/slashes/metacharacters, a shell builtin/keyword, or a name that already resolves on PATH (unless you are reclaiming that exact name).

**Abort:** delete `/tmp/baton-done-<session_id>` before the turn ends and nothing is ever armed. Setting or unsetting an env var in the terminal does **not** abort an armed relaunch - the helper is a detached process with a frozen environment. Deleting the done-flag does not stop one either: the helper never reads it.

**First use:** the relaunch is a real process termination, not a `/clear`. Before relying on it, run it once in your real terminal and confirm the session ends only after a turn completes and the fresh session comes back with your progress injected. The driver is off by default and abortable (delete the done-flag), and every committed action is logged, so a mis-fire is diagnosable.

## Manual checkpoint (/pass-the-baton:renew)

Run `/pass-the-baton:renew` to fire a checkpoint immediately, before the context-fill threshold is reached. It arms a one-shot per-session flag that the checkpoint hook consumes on your next action, running the identical save-and-handoff path as an automatic threshold crossing. It is context-% independent, so it works even if your statusline is not emitting a percentage.

It composes with whichever driver is active (tmux or relaunch): after the save, the same driver continues the session.

Manual smoke: after invoking `/pass-the-baton:renew`, the flag file `/tmp/baton-force-checkpoint-$CLAUDE_CODE_SESSION_ID` exists until your next action consumes it.

## See also

- [context-baton.md](context-baton.md) - full env-var table + state schema.
- [project-context.md](project-context.md) - `project-context.json` role mapping.
- [cli.md#toolsbaton-dashboardsh](cli.md#toolsbaton-dashboardsh) - the dashboard CLI that writes `config.json`.
- [architecture.md](architecture.md) - where these files sit in the data flow.
