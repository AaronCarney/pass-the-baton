# Pass the Baton

Save your Claude Code session at 23% context fill. Resume on next session with the assignment auto-injected.

![Baton Tests](https://github.com/AaronCarney/pass-the-baton/actions/workflows/baton-tests.yml/badge.svg)

> A session-continuity layer for [Claude Code](https://claude.com/claude-code). A handful of hooks + a small state model + a self-running cleanup sweep = no more lost context across `/clear`.

**Not Claude Code's `/rewind`.** Claude Code v2.0+ ships a built-in "Checkpointing" feature (`Esc Esc` or `/rewind`) that snapshots file edits so you can roll back individual changes. Pass the Baton is unrelated: it persists *whole sessions* across terminal restarts and crashes, using context-fill triggers and an append-only event log. The two run side-by-side without conflict.

---

## What It Does

```
Context fills to 23%   ──►  PreToolUse hook flags this terminal "save pending"
You write progress.md  ──►  PostToolUse hook archives old progress, binds the new one to your terminal
You /clear             ──►  ...
Next session starts    ──►  SessionStart hook reads your terminal's binding,
                            injects the progress file as a MANDATORY directive
```

The 23% trigger fires **once per session**, then **defers** until you actually write a progress file - so checkpoints capture your latest thinking, not stale context.

State is a two-file model:
- `terminals/<hash>.json` - which workstream this terminal is bound to
- `workstreams/<name>.json` - what progress file is current for that workstream

Old progress files auto-archive on each save. A cleanup sweep (every 48h) prunes dead workstreams and stale terminal bindings - it runs automatically on session start, so no manual cron setup is required; an optional crontab line is available as a fallback for machines where you rarely start Claude Code.

---

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add AaronCarney/pass-the-baton
/plugin install pass-the-baton@pass-the-baton
```

This installs the hooks + skills. Core continuity works immediately and the cleanup sweep runs automatically on session start - no cron setup required. Restart Claude Code (or start a new session) so the hooks load.

The optional statusline context-fill readout (`CTX:NN%`) is not wired by the plugin install. To add it, say *"set up the Pass the Baton statusline"* (the `install-baton` skill walks it, confirming before any durable write) or follow [`docs/install.md`](docs/install.md).

### Guided install via the skill

> *Please install Pass the Baton into this project.*

Claude Code's `install-baton` skill detects your target project from `$PWD`, walks the 5 first-time-setup prompts, wires the statusline (confirms before writing), runs `verify-install.sh`, and points you at `/baton` for ongoing tuning. Use this when you want the statusline + interactive setup.

If Claude Code isn't installed yet: [claude.com/claude-code](https://claude.com/claude-code).

<details>
<summary>Manual install (no Claude Code, or scripted) - fallback</summary>

```bash
git clone https://github.com/AaronCarney/pass-the-baton.git
cd pass-the-baton
bash tools/install.sh --target /path/to/your/project
```

`--target` is the project you want checkpointed - typically the repo you spend Claude Code sessions in, not this clone. Omitting it defaults the state, `.gitignore` entry, and cron pointer to whatever `$PWD` is at install time.

5 interactive prompts; or `--non-interactive` for CI / scripted installs. Idempotent - re-running is a no-op.

**Platforms.** Linux + WSL2 are the primary targets. **macOS / BSD support is deferred** - hooks use GNU `grep -P \K` and GNU `find -mmin` (see [`docs/install.md` § Platform Support](docs/install.md#platform-support)).

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

Plugins update from the marketplace on demand; toggle auto-update in `/plugin` settings to pull new revisions automatically. Releases are **commit-SHA versioned** - `plugin.json` intentionally omits a semver `version`, so the installed revision tracks the marketplace repo's HEAD commit rather than a tag. As a freshness signal, the SessionStart staleness probe surfaces a `last swept Nh ago` notice when the cleanup sweep (and therefore your last session, where updates are pulled) hasn't run recently.

---

## Configuration

The most common knob is the trigger threshold:

```bash
export BATON_PCT_THRESHOLD=23   # default; integer percent of context window
```

Drop a lower number if you want earlier checkpoints (more margin before auto-compact), raise it if 23% is too eager. The hook reads it on each PreToolUse, so changes take effect immediately.

Other commonly-set env vars:

| Var | Default | Effect |
|---|---|---|
| `BATON_TIMING` | unset | `=1` enables per-tool latency telemetry (`tool_call` events) |
| `BATON_OUTCOME_PROXIES` | unset | `=1` enables outcome-quality proxy emission (see [`docs/install.md` §4](docs/install.md#4-outcome-quality-proxies-opt-in)) |
| `BATON_PREWARM` | unset | `=1` issues one max-tokens-0 API call at SessionStart to warm the prompt cache |
| `BATON_EVENT_LOG_DISABLE` | unset | `=1` suppresses all telemetry emission |

Full env-var table (paths, TTLs, archive dirs): [`docs/context-baton.md` § Configuration](docs/context-baton.md#configuration-env-vars).

### `/baton` skill + progress-file templates

The active progress-file template controls what your checkpoint *looks* like. Three ship in [`share/templates/`](share/templates/):

| Template | When to use |
|---|---|
| `free` | Unstructured Claude Code use; prose-only session notes |
| `task` | Semi-structured project work outside a formal L1/L2 plan |
| `factory` | Full software-factory workflow with L1/L2 plan awareness and JSON Task State |

Custom templates can be installed at `$XDG_CONFIG_HOME/baton/templates/<name>.md`; see [`share/templates/README.md`](share/templates/README.md) for the placeholder convention and section-manifest sidecar format.

The active template, threshold percent, and a few other knobs are managed by the `/baton` skill (UI surface for `tools/baton-dashboard.sh`):

```bash
tools/baton-dashboard.sh show
tools/baton-dashboard.sh set template=task threshold_pct=20
```

Flag-by-flag reference: [`docs/cli.md § baton-dashboard.sh`](docs/cli.md#toolsbaton-dashboardsh). Template design rationale and the validation pipeline live in [`docs/context-baton.md § Progress File Format`](docs/context-baton.md#progress-file-format).

---

## For Two Audiences

### 1. Solo Claude Code user

Drop the hooks in, write a progress file when you hit ~23%, /clear, and your next session starts knowing exactly where you left off. Zero orchestration. The plugin (or install script) wires the continuity hooks into Claude Code and the cleanup sweep runs itself on session start. You can stop reading here.

### 2. Software-factory / multi-agent integrator

The pipeline is designed to compose with custom orchestration:

- **Multi-workstream:** terminal-bound state lets parallel agents/sub-agents each carry their own progress file, isolated by terminal hash. `tools/resume.sh` lists active + archived workstreams and rebinds the current terminal.
- **State model is documented:** `terminals/<hash>.json` and `workstreams/<name>.json` are stable contracts (see [`docs/context-baton.md`](docs/context-baton.md) for the schema).
- **Everything is `BATON_*`-overridable:** project dir, archive dir, threshold percent, TTLs - see the env-var table in [`docs/context-baton.md`](docs/context-baton.md#configuration-env-vars).
- **Three integration patterns** for composing with existing pipelines: drop-in, multi-workstream, pre-commit gate. See [`docs/integration-patterns.md`](docs/integration-patterns.md).
- **`verify-install.sh --pre-commit-only`** is a fast smoke gate (no full suite) suitable as a pre-commit hook in your own CI.

---

## How It Works

| Stage | Hook | Event | What |
|---|---|---|---|
| Trigger | `context-checkpoint.sh` | PreToolUse | At threshold (default 23%), flag this terminal's workstream `progress_file = "pending"` |
| Save | `checkpoint-write-trigger.sh` | PostToolUse | When you Write/Edit a progress file with the flag set: archive prior progress, atomically update workstream record under `flock` |
| Inject | `session-start.sh` | SessionStart | Route via `WORKSTREAM` env → terminal hash → fresh workstream; inject bound progress as MANDATORY directive |
| Label | `project-detect.sh` | UserPromptSubmit | Detect `projects/<name>` mentions or explicit `rename this session to X`; updates the workstream's `display_name` |
| Cost telemetry | `post-tool-batch.sh` | PostToolBatch | Per-turn token usage from transcript → `cost_rollup` event; flags 2× `cache_creation` jumps → `cache_anomaly` |
| Latency telemetry | `tool-timing.sh` | PostToolUse (all) | **Opt-in** (`BATON_TIMING=1`) - emits `tool_call` with SDK `duration_ms` + self-measured `hook_overhead_ms` |
| Lifecycle | `cleanup-on-exit.sh` | SessionEnd | Per-session housekeeping on terminal close |
| Sweep | `cleanup-cron.sh` | auto (SessionStart, `--if-due`) | Archive dead workstreams (progress file gone), prune terminal bindings stale > 72h; self-throttled to the 48h interval (`BATON_SWEEP_INTERVAL_HOURS`), runs detached so it never delays session start; optional crontab fallback |

Routing precedence on SessionStart:
1. `WORKSTREAM` env var (most explicit)
2. `AGENT_SESSION_ID` (for sub-agents - short-circuits)
3. Terminal hash lookup (`terminals/<hash>.json`)
4. Fresh workstream created

Full design + env vars + state schema + troubleshooting: [`docs/context-baton.md`](docs/context-baton.md).
Telemetry / event-log design: [`docs/telemetry.md`](docs/telemetry.md).
Cost model / pricing primitives / token estimation: [`docs/cost-model.md`](docs/cost-model.md).

- `bash tools/cost-compare.sh` - checkpoint-threshold cost trade-off and resume-pattern cache-payoff analysis for a session.
- `tools/latency.sh` - quantile reporting over `hook-events.jsonl`: per-tool latency, instrumentation overhead, summarizer-window pairing, cleanup-hook duration. Requires `BATON_TIMING=1` to collect data.

---

## What We Don't Promise

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

Pass the Baton is local-only. There is no network code path. Nothing is transmitted off-machine - not state, not event logs, not telemetry. Two append-only event logs are written, both mode 0600 and both local-only:

- **Structured telemetry log** - `$XDG_STATE_HOME/baton/hook-events.jsonl` (typically `~/.local/state/baton/hook-events.jsonl`), written by `envelope::emit` in `.claude/hooks/lib/envelope.sh`. Frozen `schema_version=1`, redacted, 4 KiB record cap. This is the file `tools/query.sh`, `tools/cost.sh`, and `tools/latency.sh` read. Set `BATON_EVENT_LOG_DISABLE=1` to suppress all emission to this file.
- **Project-local forensic audit log** - `$BATON_DIR/hook-events.jsonl` (typically `<repo>/.baton/hook-events.jsonl`, gitignored), written by `log_event` in `.claude/hooks/lib/workstream-lib.sh`. Captures workstream selection outcomes, basename-rejects, and sticky writes - separate file with the same basename, not the same file as the telemetry log above. Documented at [`docs/context-baton.md`](docs/context-baton.md#files) (Files table row + Troubleshooting `jq` examples).

Prompt and completion text are never captured by either writer; tool arguments are summarized (name, length, hash) rather than written verbatim. Full schema, env-var controls, and redaction rules for the structured telemetry log are documented in [`docs/telemetry.md`](docs/telemetry.md).

---

## Tests

102 shell test suites, grouped by concern:

- **Core flow:** `test-workstream-hooks.sh`, `test-restore-workstream.sh`, `test-resume.sh`, `test-prompt-sync.sh`
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
.claude/skills/   # /resume, /baton, and install-baton slash commands
lib/              # cost + token primitives (pricing, byte→token estimator, transcript reader)
tools/            # CLIs - install, verify, resume, cleanup, query, cost, doctor, recommend, latency
assets/, share/   # statusline % helper; progress-file templates + logrotate config
docs/             # reference docs - start at docs/README.md
```

Full per-file annotated tree: [`docs/repo-layout.md`](docs/repo-layout.md).

---

## License

MIT - see [LICENSE](LICENSE).
