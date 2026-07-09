# Architecture

Pass the Baton is a set of Claude Code hooks that read session signals, write a small state model, and emit an append-only event log that the analysis tools read back. The system has four layers that data flows through in order: **hooks → libs → state → tools**. Hooks fire on Claude Code lifecycle events and turn raw session signals into actions; the libs are the shared logic those hooks call; state is the small set of files that get persisted; and the tools read state and the event log back for analysis and control.

This doc explains *how the pieces connect* - the layers and the seams between them. For the annotated file tree (what each file is), see [repo-layout.md](repo-layout.md).

## Hooks (the entry points)

The hooks are the only code Claude Code invokes directly. They fire on lifecycle and telemetry events:

- **Trigger** (`context-checkpoint.sh`, PreToolUse) - at the configured threshold, flags this terminal's workstream so the next progress write gets archived.
- **Save** (`checkpoint-write-trigger.sh`, PostToolUse) - when you Write/Edit a progress file with the flag set, archives the prior progress and atomically updates the workstream record.
- **Inject** (`session-start.sh`, SessionStart) - resolves which workstream this terminal binds to and injects its bound progress as a mandatory directive.
- **Cost** (`post-tool-batch.sh`, PostToolBatch) - per-turn token usage from the transcript into a `cost_rollup` event.
- **Subagent cost** (`post-subagent-cost.sh`, SubagentStop) - each finished sub-agent's own transcript usage, stamped to the open arc.
- **Latency** (`tool-timing.sh`, PostToolUse) - opt-in per-tool timing into `tool_call` events.
- **Cleanup** (`cleanup-on-exit.sh`, SessionEnd) - per-session housekeeping on terminal close.
- **Detect** (`project-detect.sh`, UserPromptSubmit) - detects `projects/<name>` mentions and explicit renames; updates the workstream `display_name`.
- **Outcome proxies** (`outcome-proxy-code-execution.sh`, `outcome-proxy-retry-density.sh`) - opt-in signals derived from the same session stream.

The continuity path is **trigger → save → inject**: the trigger sets a pending flag, the next progress write saves and archives, and a later SessionStart injects that progress back. On SessionStart, the workstream is resolved by a fixed routing precedence: `AGENT_SESSION_ID` (sub-agents short-circuit here to a read-only fast path) → `WORKSTREAM` env var → terminal-hash lookup → fresh workstream. Rather than restate every hook's exact behavior, see the per-hook table in the [README How It Works](../README.md#how-it-works).

## Libs (shared logic)

The hooks stay thin by delegating to two lib layers.

`.claude/hooks/lib/*` holds the hook helpers: `envelope.sh` (telemetry writer), `workstream-lib.sh` (workstream record reads/writes under lock), `template-render.sh` / `template-resolve.sh` (progress-directive rendering), `rolloff.sh` (progress archival), `usage-tokens.sh` (the shared five-field usage extractor), `session-start-helpers.sh`, and the project/outcome helpers. The top-level `lib/*` holds the cost and token primitives the analysis tools build on (`config.sh`, `eventlog.sh`, `cost-models.sh`, `tokens.sh`, `recommend-*`, and friends).

Two seams in this layer are **single-writer** by design and everything else goes through them:

- **`envelope.sh`** is the sole writer of the structured event log - every emitted event passes through `envelope::emit`, so telemetry never drifts between producers.
- **`config.sh`** (`_cfg::get` / `_cfg::set`) is the single read/write path for runtime config, so the routing precedence (env → config.json → default) is applied in one place.

## State (what gets persisted)

The persisted state is deliberately small:

- **Two-file workstream model** - `terminals/<hash>.json` (this terminal's binding) points to `workstreams/<name>.json` (the durable workstream record). The Inject hook walks terminal → workstream.
- **Runtime `config.json`** - the on-disk config surface that `config.sh` reads.
- **Progress files + their archive** - the live progress doc plus the rolled-off prior versions the Save hook archives.
- **Two append-only event logs** - the structured telemetry log (written by `envelope.sh`) and the project-local forensic log (`.baton/hook-events.jsonl`).

See [context-baton.md](context-baton.md) for the state schemas and the two-file design, and [configuration.md](configuration.md) for the `config.json` knobs.

## Tools (read-back + control)

The tools are read-back and control surfaces that consume the state and event log the hooks produced. The analysis CLIs include `query` (arbitrary SQL over the event log), `cost` and `cost-compare` (spend rollups and counterfactuals), `recommend`, `latency`, and `doctor` (install/health check). The control surfaces include `resume` (rebind this terminal to a workstream), `project.sh` (open/close measurement arcs), and `baton-dashboard`.

See [cli.md](cli.md) for the flags and [telemetry.md](telemetry.md) for the event schema the queries read.

## Collection is gated

No event is written unless a measurement arc is open or `BATON_COLLECT=1` is set - there is no always-on structured telemetry. See [arc.md](arc.md) for how arcs gate collection. The telemetry log is local-only and redacted before it is written; see [telemetry.md](telemetry.md) for what is and isn't captured.

Concrete numbers - thresholds, intervals, and the like - live in [configuration.md](configuration.md) and the [README How It Works](../README.md#how-it-works) table, not here.

## Where to go next

- [repo-layout.md](repo-layout.md) - the annotated file tree.
- [configuration.md](configuration.md) - the config knobs and precedence.
- [context-baton.md](context-baton.md) - the continuity design and state schema.
- [telemetry.md](telemetry.md) - the event-log schema.
