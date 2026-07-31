# CLI reference

Cross-tool reference for the four tools that don't get a dedicated page elsewhere. For tools that have their own doc (`recommend.sh`, `project.sh`, `time-to-complete-corpus.sh`, the cost suite), see the index in [README.md](README.md).

This page covers:

- [`tools/cost.sh`](#toolscostsh) - per-session cost breakdown from Claude Code transcripts
- [`tools/doctor.sh`](#toolsdoctorsh) - environment health probe
- [`tools/baton-dashboard.sh`](#toolsbaton-dashboardsh) - get/set the global `/baton` config, or open the interactive dashboard
- [`tools/project.sh`](#toolsprojectsh) - per-project session ledger

All four tools are read-only against the event log unless documented otherwise. None require network access.

---

## `tools/cost.sh`

Reads a Claude Code transcript JSONL and computes a per-primitive cost breakdown (cache reads, 5m/1h cache writes, base input, output) using the prices in [`lib/cost-models.sh`](../lib/cost-models.sh). See [cost-model.md](cost-model.md) for methodology, accuracy bounds, and the four method arms.

### Usage

```bash
tools/cost.sh [--session <uuid>] [--model <id>] [--geo us] [--fast]
              [--verify] [--corpus DIR] [--self-check] [--last N]
              [--json] [--distribution] [--transcript <path>]
              [--compare ...]
```

### Flags

| Flag | Description |
|---|---|
| `--session <uuid>` | Inspect a specific session by Claude Code session UUID. |
| `--transcript <path>` | Cost a specific JSONL transcript file (bypasses session lookup). |
| `--model <id>` | Price against a specific model alias or pinned ID (e.g. `claude-sonnet-4-6`, `claude-opus-4-7-20260514`). Defaults to `$BATON_COST_MODEL` or `claude-sonnet-4-6`. |
| `--geo us` | Apply the US-region 1.10× geo multiplier. |
| `--fast` | Apply the Opus 4.x fast-mode 6.00× multiplier (Opus only). |
| `--last N` | Cost the most recent `N` sessions instead of one. |
| `--json` | Emit machine-readable JSON instead of the formatted breakdown. |
| `--distribution` | Print a per-primitive distribution table across the inspected sessions. |
| `--verify --corpus DIR` | Calibrate bytes-per-token ratios against a real corpus and rewrite `$BATON_TOKEN_RATIOS`. Refuses to run without `--corpus` (CC8: session text must not be its own corpus). |
| `--self-check` | Run the arithmetic-identity assertion suite (linearity, additivity, geo/fast multipliers, absolute price anchors). Non-zero exit on any failure. Used as the in-band cost-engine regression gate. |
| `--compare ...` | Delegate to `tools/cost-compare.sh` for cross-method comparison; remaining flags are forwarded. |

### Environment

| Variable | Purpose |
|---|---|
| `BATON_COST_MODEL` | Default model when `--model` is omitted. |
| `BATON_TRANSCRIPT_PATH` / `BATON_TRANSCRIPT_DIR` | Override transcript discovery (testing / non-standard installs). |
| `BATON_TOKEN_RATIOS` | Path to the calibrated bytes-per-token file. Default: `$HOME/.config/baton/token-ratios.sh`. |
| `BATON_COST_MODELS_PATH` | Alternate `cost-models.sh` (used by `--self-check` mutation test). |

### Exit codes

`0` success · `1` self-check failure · `2` argument error (unknown flag, unknown model, missing `--corpus` with `--verify`).

---

## `tools/doctor.sh`

Read-only environment probe. Run it when something doesn't fire. Always prints a `summary:` line; exits `0` if all green, `1` if any warning fired.

### Usage

```bash
tools/doctor.sh
```

No flags. Reads `$BATON_EVENT_LOG` (default `$XDG_STATE_HOME/baton/hook-events.jsonl`).

### Checks

1. **Event-log resolution.** Prints the resolved log path and parent-dir mode.
2. **Filesystem type.** Warns if the log lives on `nfs`/`nfs4`/`cifs`/`smbfs` - `flock` semantics are unreliable there.
3. **Log-file mode.** Expects `0600`; warns otherwise.
4. **Cache anomalies (last 24h).** Counts `cache_anomaly` events in the log (emitted by `post-tool-batch.sh` on 2× cache_creation jumps).
5. **Pricing freshness.** Warns if `PRICING_VERIFIED_DATE` in `lib/cost-models.sh` is more than 90 days old - re-verify against Anthropic's pricing page.

### Environment

`BATON_EVENT_LOG` - override the log path. `BATON_COST_MODELS_PATH` - override the `cost-models.sh` consulted for freshness.

---

## `tools/baton-dashboard.sh`

The `/baton` skill's backing CLI. Reads and writes `$XDG_CONFIG_HOME/baton/config.json` under an `flock`-guarded update path. Use it when you don't want to edit the config file by hand.

### Usage

```bash
tools/baton-dashboard.sh                 # no args: same as `show`
tools/baton-dashboard.sh show
tools/baton-dashboard.sh set key=value [key2=value2 ...]
tools/baton-dashboard.sh tui             # interactive tabbed dashboard; needs a real terminal
```

`show` annotates each key with its effective source - `[env]` (an exported `BATON_*` var), `[config]` (a value written to `config.json`), or `[default]` (the compiled default) - so a configured value is never mistaken for a built-in default.

### Keys

| Key | Type | Purpose |
|---|---|---|
| `template` | enum: `free` / `task` / `factory` / custom | Active progress-file template. Custom templates resolve from `$XDG_CONFIG_HOME/baton/templates/<name>.md`. |
| `threshold_pct` | integer 1-99 | Context-fill % that triggers the deferred checkpoint. Default `20`. |
| `display_name` | string | Friendly workstream display name. |
| `templates_dir` | path | Override for the custom-templates directory. |
| `project_context_file` | path | Per-project context JSON; default `.baton-project/project-context.json`. |
| `max_terminals_per_workstream` | integer >= 0 | Cap on terminals bound to one workstream. |
| `auto_continue_mode` | enum: `off` / `tmux` / `relaunch` | Auto-continue driver the `baton` launcher (`tools/baton-run.sh`) dispatches on. Default `off`; legacy `BATON_AUTO_CONTINUE=1` resolves to effective `tmux`. |
| `launch_alias` | alias name | Installs/rewrites a marker-guarded `alias <name>='bash <repo>/tools/baton-run.sh'` rc block. Rejects empty names, metacharacters, shell builtins/keywords, and names already on PATH. |

### Interactive mode (`tui`)

```bash
tools/baton-dashboard.sh tui
```

`interactive` and `dashboard` are accepted as aliases for `tui`.

The TUI needs a real terminal: it checks that stdin *and* stdout are both TTYs and prints plain `show` output instead when either is not, so it stays safe in pipes, scripts, cron, and agent tool calls.

| Tab | Key | Contents |
|---|---|---|
| Status | `1` | Read-only live monitor: context fill %, the checkpoint threshold, the effective `auto_continue_mode`, whether a checkpoint is owed, and the session id bound to this terminal. |
| Config | `2` | The editor. One row per editable key `show` prints, carrying the same label, value, and effective-source tag: `[env]`, `[config]` or `[default]` for keys routed through `_cfg::get`, and `[config-only]` for keys read straight out of `config.json`. (`[env-only by design]` tags only `BATON_DIR` and `BATON_PROJECT_DIR`, which this tab omits - see below.) |
| History | `3` | The last 10 entries from `tools/cost.sh --last 10`. Needs `jq`; says so when `jq` is absent, and prints a notice rather than a table when the event log has nothing yet. |
| Workstreams | `4` | The `*.md` progress files found in `BATON_PROGRESS_DIR`. |

| Key | Action |
|---|---|
| `1`-`4` | Switch tab |
| `up` / `down` | Move the cursor (Config tab only) |
| `enter` | Edit the selected key (Config tab only) - prompts for a new value and writes it through the same validation path as `set` |
| `r` | Redraw |
| `q` | Quit |

`BATON_DIR`, `BATON_PROJECT_DIR` and `template_version` are **read-only**. `show` prints them, but the Config tab omits them entirely rather than offering an edit that `set` would not write.

### Safety

`set template=...` refuses to switch while a checkpoint is in flight (a `/tmp/baton-pending-*` flag is set). Wait for the next progress write to clear, then retry.

---

## `tools/project.sh`

Per-project session ledger - marks the start/end of a working session against a project slug so cost and time analysis can attribute by project. See [projects.md](projects.md) for the data model and `project-context.json` integration.

### Usage

```bash
tools/project.sh mark-start <slug> [--description TEXT]
tools/project.sh mark-end <slug> --status success|abandoned|paused [--note TEXT]
tools/project.sh list [--active|--all]
tools/project.sh show <slug>
```

### Environment

| Variable | Purpose |
|---|---|
| `CLAUDE_WORKSTREAM` | Workstream id. Defaults to `unassociated` if unset. |
| `CLAUDE_TERMINAL_ID` | Terminal id. Defaults to `hostname-PPID`. |

### Exit codes

`0` success · `1` argument error (missing slug, unknown flag, bad enum) · `2` state error (no such project, double-start, mismatched end).
