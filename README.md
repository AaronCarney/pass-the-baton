# Pass the Baton

The hardest part of a long coding session isn't the work. It's starting over.

A session ends - context fills up, the terminal closes, something crashes - and the thread goes with it: what you'd tried, what had broken, what was coming next. The one after it opens to a blank slate, and you're left holding all of it, explaining where things stood before any real work can begin again.

**Pass the Baton hands that off for you.** As your context fills, it saves where you are. When you start again, that gets passed straight to the next session - so it picks up the work instead of starting cold.

**The novelty isn't the refresh.** Saving and restoring a session is table stakes now. Two things set this apart. First, the handoff is a general substrate rather than a single feature: the same mechanism carries whatever you layer on top, so your own hooks, skills, and custom ecosystem ride along instead of being bolted on. Second, it is built for many terminals at once, including several open on the same project (even in the same root folder), kept safe from clobbering each other by a stack of deliberate edge-case protections.

**▶ Watch the demo** - _(coming soon)_

![Baton Tests](https://github.com/AaronCarney/pass-the-baton/actions/workflows/baton-tests.yml/badge.svg)

> A session-continuity layer for [Claude Code](https://claude.com/claude-code): a handful of hooks, a small state model, and a self-running cleanup sweep - so context survives `/clear`, crashes, and restarts.

**Not Claude Code's `/rewind`.** Claude Code v2.0+ ships a built-in "Checkpointing" feature (`Esc Esc` or `/rewind`) that snapshots file edits so you can roll back individual changes. Pass the Baton is unrelated: it persists *whole sessions* across terminal restarts and crashes, using context-fill triggers and an append-only event log. The two run side-by-side without conflict.

---

## What It Does

The handoff is built out of Claude Code hooks - small scripts that fire at points in a session's life. Here is the whole arc.

As a session runs, one hook watches how full the context window is. When it crosses a threshold - 20% by default, and you can move it - it doesn't interrupt you. It quietly flags that a checkpoint is due, then waits. The next time you write your progress file, that write is what gets saved. So the checkpoint captures your latest thinking, not whatever stale state happened to be live the moment the threshold tripped.

That saved progress is bound to your terminal - not to the folder you are working in. This is the part that makes running more than one session at a time safe: you can have several Claude Code sessions open at once, in different repos, in the same repo, even in the same workspace, and each keeps its own separate handoff. Two sessions in the same directory never overwrite each other's state, because the binding key is the terminal, not the path.

When you `/clear`, crash, or simply open a new session, a start-up hook looks up that terminal's binding and injects the bound progress file as a mandatory directive - the new session reads where it left off before it does anything else.

Underneath, the whole thing is two small JSON files: one mapping your terminal to a workstream, one recording that workstream's current progress file. Old progress files archive themselves on every save. A cleanup sweep prunes dead workstreams and stale terminal bindings; it runs itself on session start - throttled, and in the background - so there is no cron to set up.

And it all stays local. Your progress, your state, your logs - none of it ever leaves the machine.

---

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add AaronCarney/pass-the-baton
/plugin install pass-the-baton@pass-the-baton
```

That's the whole install - it wires in the hooks and skills. Continuity works right away, and the cleanup sweep takes care of itself on session start, so there's no cron to set up. Restart Claude Code (or open a new session) so the hooks load.

The statusline context-fill readout (`CTX:NN%`) is optional and isn't wired by the plugin. To add it, just say *"set up the Pass the Baton statusline"* - the `install-baton` skill walks you through it and confirms before writing anything - or follow [`docs/install.md`](docs/install.md).

### Guided install via the skill

> *Please install Pass the Baton into this project.*

Say that to Claude Code and the `install-baton` skill takes over: it finds your target project from `$PWD`, walks the 6 setup prompts, wires the statusline (confirming first), runs `verify-install.sh`, and points you at `/baton` for ongoing tuning. Use this path when you want the statusline and an interactive setup.

Don't have Claude Code yet? [claude.com/claude-code](https://claude.com/claude-code).

<details>
<summary>Manual install (no Claude Code, or scripted) - fallback</summary>

```bash
git clone https://github.com/AaronCarney/pass-the-baton.git
cd pass-the-baton
bash tools/install.sh --target /path/to/your/project
```

`--target` is the project you want checkpointed - usually the repo you actually run Claude Code in, not this clone. Leave it off and the state, `.gitignore` entry, and cron pointer default to whatever `$PWD` is at install time.

5 interactive prompts; or `--non-interactive` for CI / scripted installs. It's idempotent - re-running is a no-op.

**Platforms.** Linux and WSL2 are the primary targets. **macOS / BSD support is deferred** - the hooks use GNU `grep -P \K` and GNU `find -mmin` (see [`docs/install.md` § Platform Support](docs/install.md#platform-support)).

**Core install** needs `jq`, `flock`, GNU `grep`/`find`, `md5sum`, `bash 4.4+`.
**Analysis tools** (`tools/query.sh`, `tools/recommend.sh`, `tools/cost-compare.sh`) need `duckdb`, `bc`, and `python3 -m pip install -r requirements.txt`. The installer warns if any are missing - core install still proceeds.

Verify: `bash tools/verify-install.sh`
Uninstall: `bash tools/uninstall.sh`

</details>

Full setup including the dep table + statusline + manual cron fallback: [`docs/install.md`](docs/install.md).

### Updating

```
/plugin update pass-the-baton
```

Plugins update from the marketplace on demand; toggle auto-update in `/plugin` settings to pull new revisions automatically. Releases are **semver-versioned** - `plugin.json` carries the current `version` and each release is recorded in [`CHANGELOG.md`](CHANGELOG.md). As a freshness signal, the SessionStart staleness probe surfaces a `last swept Nh ago` notice when the cleanup sweep (and therefore your last session, where updates are pulled) hasn't run recently.

---

## Configuration

The knob you'll reach for most is the trigger threshold. It resolves from three sources, highest priority first: the `BATON_PCT_THRESHOLD` environment variable, the `threshold_pct` key in `config.json` (written by the dashboard - see [Controlling your settings](#controlling-your-settings)), then the built-in default of 20. An integer from 1 to 99 is honored; anything else (non-integer, zero, negative, or 100 and up) falls back to 20.

```bash
export BATON_PCT_THRESHOLD=20   # integer percent of context window; default 20
```

Lower it for earlier checkpoints (more margin before auto-compact), raise it if the default feels too eager. When exported, the environment variable beats the config value and also pins the [adaptive tuner](#controlling-your-settings) so it won't auto-adjust. The hook re-reads the resolved threshold on every PreToolUse.

Other env vars you might set:

| Var | Default | Effect |
|---|---|---|
| `BATON_TIMING` | unset | `=1` enables per-tool latency telemetry (`tool_call` events) |
| `BATON_OUTCOME_PROXIES` | unset | `=1` enables outcome-quality proxy emission (see [`docs/install.md` §4](docs/install.md#4-outcome-quality-proxies-opt-in)) |
| `BATON_PREWARM` | unset | `=1` issues one max-tokens-0 API call at SessionStart to warm the prompt cache |
| `BATON_EVENT_LOG_DISABLE` | unset | `=1` suppresses all telemetry emission |
| `BATON_AUTO_CONTINUE` | unset | `=1` still means tmux: auto-drives `/clear` + a continue nudge into your pane after a checkpoint; clean no-op otherwise. `BATON_AUTO_CONTINUE_MODE` (`off`\|`tmux`\|`relaunch`) now picks the driver. See [`docs/configuration.md` § Auto-continue](docs/configuration.md) |

Full env-var table (paths, TTLs, archive dirs): [`docs/context-baton.md` § Configuration](docs/context-baton.md#configuration-env-vars).

### Auto-continue + the `baton` launcher

After a checkpoint saves, Pass the Baton can continue the session for you instead of leaving you to `/clear` and re-prompt by hand. The driver is the `auto_continue_mode` config key (`off` by default; `tmux` drives `/clear` + a continue nudge into your pane, `relaunch` runs a fresh-session supervisor loop). Opt into a `baton` launch alias at install time (the 6th prompt) - then you launch with `baton` instead of `claude`, and it honors whichever driver you've set. Switch drivers any time with `/baton set auto_continue_mode=tmux`. Details: [`docs/configuration.md` § Auto-continue](docs/configuration.md).

Need to hand off early, before the threshold trips? Run **`/pass-the-baton:renew`** - it fires a checkpoint immediately, running the identical save-and-handoff path as an automatic threshold crossing, independent of the reported context %.

### `/baton` skill + progress-file templates

The active progress-file template controls what your checkpoint *looks like*. Three ship in [`share/templates/`](share/templates/):

| Template | When to use |
|---|---|
| `free` | Unstructured Claude Code use; prose-only session notes |
| `task` | Semi-structured project work outside a formal L1/L2 plan |
| `factory` | Full software-factory workflow with L1/L2 plan awareness and JSON Task State |

You can install your own at `$XDG_CONFIG_HOME/baton/templates/<name>.md`; see [`share/templates/README.md`](share/templates/README.md) for the placeholder convention and section-manifest sidecar format.

The active template, threshold percent, and a few other knobs are managed by the `/baton` skill (a UI surface over `tools/baton-dashboard.sh`):

```bash
tools/baton-dashboard.sh show
tools/baton-dashboard.sh set template=task threshold_pct=20
```

Flag-by-flag reference: [`docs/cli.md § baton-dashboard.sh`](docs/cli.md#toolsbaton-dashboardsh). Template design rationale and the validation pipeline live in [`docs/context-baton.md § Progress File Format`](docs/context-baton.md#progress-file-format).

### Controlling your settings

The threshold, active template, event collection, and other knobs persist in `config.json` - write them with the `/baton` dashboard above (`tools/baton-dashboard.sh set <key>=<value>`; `… show` prints the current values). Export the matching `BATON_*` environment variable and it overrides the `config.json` value for that knob - an exported env var always wins over the dashboard.

**Adaptive threshold tuning (optional).** `tools/tune-threshold.sh` drives a feedback controller that can adjust the threshold from your own checkpoint outcomes:

```bash
tools/tune-threshold.sh --show     # current threshold, scoring function, resolved knobs
tools/tune-threshold.sh --dry-run  # measure and propose an adjustment; apply nothing
tools/tune-threshold.sh --once     # run one cycle; apply only if every guard passes
```

`--once` applies a change only when it's outside the deadband, inside the safety band, the dwell interval has elapsed, and `BATON_PCT_THRESHOLD` isn't exported (an exported env var pins the threshold and suppresses auto-tuning). The controller ships with placeholder constants; set your own setpoint and the scoring function named by `tune_score_fn` (the `tune_*` keys in `config.json`) once you've collected outcome data.

It also runs **automatically**: each new session starts one cycle (equivalent to `--once`), but **only while event collection is on** (an open arc or `BATON_COLLECT=1`) - a normal session with collection off never auto-tunes. And until you replace the placeholder `tune_score_fn` (which defaults to a no-op `score_hold`), every automatic cycle is a guaranteed hold - so turning it on changes nothing until you opt in with a real scoring function and setpoint.

---

## Two ways to use it

### 1. Solo Claude Code user

This is most people. Drop the hooks in, write a progress file when you near the threshold, `/clear`, and your next session opens knowing exactly where you left off. No orchestration to wire up - the plugin installs the hooks and handles the rest. You can stop reading here.

### 2. Software-factory / multi-agent integrator

If you're running your own orchestration, the pieces are built to slot into it:

- **Many workstreams at once:** because state is bound to the terminal, parallel agents and sub-agents each carry their own progress file, isolated by terminal hash. Reopen a session with `claude --resume` to reacquire its workstream automatically; an archived (idle) workstream can be restored with `tools/restore-workstream.sh <ws-id>`.
- **The state model is a documented contract:** `terminals/<hash>.json` and `workstreams/<name>.json` are stable shapes (schema in [`docs/context-baton.md`](docs/context-baton.md)).
- **Everything is `BATON_*`-overridable:** project dir, archive dir, threshold percent, TTLs - see the env-var table in [`docs/context-baton.md`](docs/context-baton.md#configuration-env-vars).
- **Three integration patterns** for composing with an existing pipeline: drop-in, multi-workstream, pre-commit gate. See [`docs/integration-patterns.md`](docs/integration-patterns.md).
- **A fast pre-commit gate:** `verify-install.sh --pre-commit-only` is a quick smoke check (no full suite) you can drop into your own CI.

---

## How It Works

The arc described above, hook by hook:

| Stage | Hook | Event | What |
|---|---|---|---|
| Trigger | `context-checkpoint.sh` | PreToolUse | At threshold (default 20%), flag this terminal's workstream `progress_file = "pending"` |
| Save | `checkpoint-write-trigger.sh` | PostToolUse | When you Write/Edit a progress file with the flag set: archive prior progress, atomically update workstream record under `flock` |
| Inject | `session-start.sh` | SessionStart | Route via `WORKSTREAM` env → terminal hash → fresh workstream; inject bound progress as MANDATORY directive |
| Label | `project-detect.sh` | UserPromptSubmit | Detect `projects/<name>` mentions or explicit `rename this session to X`; updates the workstream's `display_name` |
| Cost telemetry | `post-tool-batch.sh` | PostToolBatch | Per-turn token usage from transcript → `cost_rollup` event; flags 2× `cache_creation` jumps → `cache_anomaly` |
| Latency telemetry | `tool-timing.sh` | PostToolUse (all) | **Opt-in** (`BATON_TIMING=1`) - emits `tool_call` with SDK `duration_ms` + self-measured `hook_overhead_ms` |
| Lifecycle | `cleanup-on-exit.sh` | SessionEnd | Per-session housekeeping on terminal close |
| Sweep | `cleanup-cron.sh` | auto (SessionStart, `--if-due`) | Archive dead workstreams (progress file gone), prune terminal bindings stale > 72h; self-throttled to the 48h interval (`BATON_SWEEP_INTERVAL_HOURS`), runs detached so it never delays session start; optional crontab fallback |

How a session picks which workstream it belongs to, in order:
1. `AGENT_SESSION_ID` (sub-agents - checked first, short-circuits to a read-only fast path)
2. `WORKSTREAM` env var (main sessions - most explicit)
3. Terminal hash lookup (`terminals/<hash>.json`)
4. A fresh workstream, if none of the above matched

Full design + env vars + state schema + troubleshooting: [`docs/context-baton.md`](docs/context-baton.md).
Telemetry / event-log design: [`docs/telemetry.md`](docs/telemetry.md).
Cost model / pricing primitives / token estimation: [`docs/cost-model.md`](docs/cost-model.md).

- `bash tools/cost-compare.sh` - checkpoint-threshold cost trade-off and resume-pattern cache-payoff analysis for a session.
- `tools/latency.sh` - quantile reporting over `hook-events.jsonl`: per-tool latency, instrumentation overhead, summarizer-window pairing, cleanup-hook duration. Requires `BATON_TIMING=1` to collect data.

---

## What it doesn't do

We'd rather be clear about the edges than oversell. Pass the Baton does not promise:

1. A stable plugin or extension API beyond the documented hooks.
2. A stable `hook-events.jsonl` schema across minor versions - additive changes within a `schema_version` only; renames bump the version.
3. Multi-agent or worktree coordination.
4. Cross-machine session sync.
5. Memory features - this is not Letta, not claude-mem, not a RAG layer.
6. Recovery of files modified outside Claude Code.
7. Compatibility with Claude Code versions we haven't tested.
8. Any SLA on issue response.

---

## Privacy

Pass the Baton is local-first. Your state, event logs, and telemetry are never transmitted off-machine - nothing about your sessions leaves the box. The one exception is the opt-in, off-by-default cache pre-warm (`BATON_PREWARM=1`), which makes a single Claude API call carrying a static system-prompt file and no session data. Two append-only event logs are written, both mode 0600 and both local-only:

- **Structured telemetry log** - `$XDG_STATE_HOME/baton/hook-events.jsonl` (typically `~/.local/state/baton/hook-events.jsonl`), written by `envelope::emit` in `.claude/hooks/lib/envelope.sh`. Frozen `schema_version=1`, redacted, 4 KiB record cap. This is the file `tools/query.sh`, `tools/cost.sh`, and `tools/latency.sh` read. Set `BATON_EVENT_LOG_DISABLE=1` to suppress all emission to this file.
- **Project-local forensic audit log** - `$BATON_DIR/hook-events.jsonl` (typically `<repo>/.baton/hook-events.jsonl`, gitignored), written by `log_event` in `.claude/hooks/lib/workstream-lib.sh`. Captures workstream selection outcomes, basename-rejects, and sticky writes - separate file with the same basename, not the same file as the telemetry log above. Documented at [`docs/context-baton.md`](docs/context-baton.md#files) (Files table row + Troubleshooting `jq` examples).

Prompt and completion text are never captured by either writer; tool arguments are summarized (name, length, hash) rather than written verbatim. Full schema, env-var controls, and redaction rules for the structured telemetry log are documented in [`docs/telemetry.md`](docs/telemetry.md).

---

## Tests

141 shell test suites, grouped by concern:

- **Core flow:** `test-workstream-hooks.sh`, `test-restore-workstream.sh`, `test-prompt-sync.sh`
- **Install / verify:** `test-install-tools.sh`, `test-installer-nfs-warn.sh`, `test-installer-post-tool-batch.sh`, `test-installer-tool-timing.sh`, `test-doctor.sh`
- **Event log + envelope:** `test-envelope.sh`, `test-event-log-e2e.sh`, `test-hook-writers.sh`, `test-query.sh`, `test-otel-mapping.sh`, `test-logrotate-snippet.sh`, `test-tools-changed.sh`, `test-pre-warm.sh`
- **Cost telemetry:** `test-cost.sh`, `test-cost-models.sh`, `test-cost-estimator-e2e.sh`, `test-post-tool-batch.sh`, `test-anomaly-detector.sh`, `test-tokens.sh`, `test-calibrate.sh`, `test-transcript.sh`, `test-cost-compare.sh`, `test-cost-compare-model.sh`
- **Latency telemetry:** `test-tool-timing.sh`, `test-latency.sh`

Run a single suite: `bash .claude/hooks/tests/<suite>.sh`.

CI runs the full suite on push/PR: [`.github/workflows/baton-tests.yml`](.github/workflows/baton-tests.yml).

Prerequisites: `jq`, `flock`, GNU `grep`/`sed`. See [`.claude/hooks/tests/PREREQS.md`](.claude/hooks/tests/PREREQS.md).

---

## Repository Layout

```
.claude/hooks/    # lifecycle + telemetry hooks (trigger, save, inject, cost, sub-agent cost, latency, cleanup, detect, opt-in outcome proxies) + lib/
.claude/skills/   # /baton (config) and install-baton slash commands (namespaced /pass-the-baton:baton under the plugin)
lib/              # cost + token primitives (pricing, byte→token estimator, transcript reader)
tools/            # CLIs - install, verify, cleanup, query, cost, doctor, recommend, latency
assets/, share/   # statusline % helper; progress-file templates + logrotate config
docs/             # reference docs - start at docs/README.md
```

Full per-file annotated tree: [`docs/repo-layout.md`](docs/repo-layout.md).

---

## License

MIT - see [LICENSE](LICENSE).
