# Public API

This document lists the parts of Pass the Baton that are stable contracts. Anything not listed here is internal and may change without notice. Semver discipline applies only to the surfaces below.

Breaking changes to any listed surface require a major-version bump and a CHANGELOG entry naming the affected contract and the migration path. Additive changes ship in minor versions. Bug fixes that restore documented behavior ship in patch versions.

The public surface is intentionally small:

1. The four **core-flow** Claude Code hook scripts and their invocation contract.
2. The `BATON_*` environment variables documented in [`docs/context-baton.md`](context-baton.md).
3. The two state-file JSON schemas (`terminals/<hash>.json`, `workstreams/<name>.json`).
4. The `hook-events.jsonl` schema and `schema_version` discipline (see [`docs/telemetry.md`](telemetry.md)).
5. One script under `tools/`: `install.sh`.

Six additional **observability** hooks ship alongside the core flow with their own (weaker) stability guarantees - see below.

Everything else is internal.

## Claude Code Hooks

Pass the Baton ships ten hook scripts, partitioned into two tiers with different stability commitments. The published plugin wires them via `hooks.json`; the in-repo dev `.claude/settings.json` wires a telemetry-only subset for development.

### Core-flow hooks (semver-protected)

These four hooks define the persistence and routing behavior. Their script paths and invocation contracts are semver-protected.

| Hook | When it fires | What we guarantee |
|---|---|---|
| `PreToolUse` (`context-checkpoint.sh`) | Before any tool call | Resolves the trigger threshold via `checkpoint_threshold` (env `BATON_PCT_THRESHOLD` > `config.json` `threshold_pct` > default 20); flags the terminal's workstream as `pending` on threshold cross. Once per session, then defers. |
| `PostToolUse` (`checkpoint-write-trigger.sh`, matcher `Write\|Edit\|MultiEdit`) | After progress-file writes | Atomically updates `workstreams/<ws>.json` under `flock` when a progress file is written while the pending flag is set. Archives the previously-bound progress file. |
| `SessionStart` (`session-start.sh`) | Session boot (matchers: `startup`, `resume`, `clear`, `compact`) | Injects the bound progress file as a mandatory directive when a terminal binding exists (no-op otherwise). In the main session, when event collection is on, also runs one adaptive-tuner control cycle and emits a `tuner_snapshot` event - inert under the placeholder scoring function. |
| `UserPromptSubmit` (`project-detect.sh`) | Every user prompt | Detects project mentions and explicit `rename this session to X` patterns; updates `workstreams/<ws>.json` `display_name`. A bare project mention rebinds the terminal to an existing same-named workstream **only when the current workstream is fresh** (never checkpointed); an established terminal keeps its binding and emits a `WORKSTREAM=<target> claude` switch hint. Explicit `WORKSTREAM=` over the co-tenancy cap soft-overrides with a warning; a bare mention over the cap is hard-blocked. CC8: never captures prompt text in event log. |

**Commitment:** These four hook script paths and their invocation contract (hook event, matcher pattern, input source, side-effect surface) are semver-protected. Renaming a script, changing its hook event, changing its matcher, or changing its input/output contract is a major-version break.

### Observability hooks (additive contract)

These six hooks emit telemetry into `hook-events.jsonl` (or do per-session housekeeping) and do not affect persistence routing. They ship with a weaker stability guarantee: behavior can change in minor versions as long as `schema_version` discipline holds for any emitted events.

| Hook | When it fires | What we guarantee |
|---|---|---|
| `PostToolBatch` (`post-tool-batch.sh`) | End of each turn | Reads transcript usage and emits `cost_rollup`; emits `cache_anomaly` on 2× `cache_creation` jumps. Behavior may change in minor versions; event names and `schema_version` are governed by [§hook-events.jsonl schema](#hook-eventsjsonl-schema) below. |
| `SubagentStop` (`post-subagent-cost.sh`) | After a Task-tool subagent returns | Reads the subagent's own transcript usage and emits a `cost_rollup` tagged `source:"subagent"`, stamped to the open arc via the inherited terminal id. Behavior may change in minor versions. |
| `PostToolUse` (`tool-timing.sh`, matcher `""`) | After every tool call | **Opt-in** (`BATON_TIMING=1`). Emits `tool_call` envelope with SDK `duration_ms` + self-measured `hook_overhead_ms`. Off-path is a no-op (env check then drain stdin). |
| `PostToolUse` (`outcome-proxy-code-execution.sh`, matcher `Bash`) | After Bash tool calls | **Opt-in** outcome-quality proxy. Emits `outcome_proxy` events; privacy contract (no command text) applies. Behavior may change in minor versions. |
| `UserPromptSubmit` (`outcome-proxy-retry-density.sh`) | Every user prompt | **Opt-in** outcome-quality proxy (retry-density signal). Emits `outcome_proxy` events; never captures prompt text. Behavior may change in minor versions. |
| `SessionEnd` (`cleanup-on-exit.sh`) | Session close | Per-session housekeeping; no envelope emitted. Behavior may change in minor versions. |

**Commitment:** Observability hooks may be added, removed, or restructured in minor versions provided (a) `schema_version` in `hook-events.jsonl` is incremented on any breaking event change, and (b) the privacy contract (no prompt/completion text, mode 0600, local-only) is never weakened. Behavior changes that *strengthen* privacy or reduce telemetry volume ship as minor versions; changes that broaden capture require a major bump.

Script paths are relative to the repo root (`.claude/hooks/...` after install).

## Environment Variables

All user-tunable configuration is exposed via `BATON_*` environment variables. The canonical table - names, defaults, semantics - lives in [`docs/context-baton.md`](context-baton.md#configuration-env-vars) and is not duplicated here.

The documented set covers:

- Location knobs (`BATON_DIR`, `BATON_PROGRESS_DIR`, `BATON_ARCHIVE_DIR`, `BATON_PROJECT_DIR`).
- Behavior knobs (`BATON_PCT_THRESHOLD`, `BATON_MAX_TERMINALS_PER_WORKSTREAM` - opt-in co-tenancy cap, default 0 = unlimited).
- Retention knobs (`BATON_WORKSTREAM_TTL_DAYS`, `BATON_TRACKING_TTL_DAYS`).
- Display knobs (`BATON_DISPLAY_NAME`).
- Event-log knobs (`BATON_COLLECT`, `BATON_EVENT_LOG`, `BATON_EVENT_LOG_DISABLE`).
- Observability opt-ins (`BATON_TIMING`, `BATON_PREWARM`).
- Summarizer-cost decoupling (`BATON_SUMMARY_MODEL`, `BATON_SUMMARY_TOKENS`).
- Adaptive-tuner knobs (`BATON_TUNE_SETPOINT`, `BATON_TUNE_DEADBAND`, `BATON_TUNE_STEP`, `BATON_TUNE_SAFETY_MIN`, `BATON_TUNE_SAFETY_MAX`, `BATON_TUNE_DWELL_SECONDS`, `BATON_TUNE_SCORE_FN`) - placeholder-valued; the controller ships inert (see [`context-baton.md`](context-baton.md#adaptive-threshold-tuner-built-not-yet-connected)).

`BATON_OTEL_EXPORT` gates the OTel export pipe: `tools/export.sh --otel` reads it via `_cfg::get` and, when set, streams the event log through `otel::rename_line` (additive `data.*` → `gen_ai.*` field renames). It remains outside the *stable* env-var surface - the `gen_ai.*` convention is still pre-stable (see [`docs/telemetry.md`](telemetry.md)), so treat the exported field names as subject to change between releases.

**Commitment:** Removing a documented `BATON_*` env var, or changing its semantic, is a major-version break. Adding new ones is additive and ships in a minor version. Renaming a variable is a major-version break even when the old name is kept as an alias - the alias period and removal release are documented in the changelog.

## State Files

The two on-disk state files are stable contracts:

- `$BATON_DIR/workstreams/<name>.json` - workstream record (progress file pointer, display name, phase).
- `$BATON_DIR/terminals/<hash>.json` - per-terminal binding to a workstream. Carries an additive optional `.closed_at` field, stamped on a clean SessionEnd (present = the terminal left cleanly; absent = live).

Schemas are documented in [`docs/context-baton.md`](context-baton.md#state-layout) and are not duplicated here. What is stable:

- The set of documented fields and their types.
- The atomicity guarantee on writes to `workstreams/<name>.json` (flock-protected, write-rename).
- The filename conventions: `<name>.json` for workstreams (alphanumeric + `-` + `_`), `<hash>.json` for terminals (md5 of `USER:<terminal-id-source>`).

**Commitment:** Additive field changes are allowed within a minor version. Renames or removals require a major bump with a documented migration path in the CHANGELOG. Consumers reading state files should ignore unknown fields.

## `hook-events.jsonl` Schema

Hooks emit JSON envelopes to `$XDG_STATE_HOME/baton/hook-events.jsonl` (overridable via `BATON_EVENT_LOG`, suppressible via `BATON_EVENT_LOG_DISABLE=1`). The full schema, env-var controls, and emitted event types are documented in [`docs/telemetry.md`](telemetry.md).

What is stable:

- The envelope shape: `{schema_version, event, ts, data}`.
- The current value `schema_version=1`.
- The privacy contract: no prompt/completion text, mode 0600 on the live log, local-only (no network).

**Commitment:** Additive event types and additive `data` fields ship within `schema_version=1`. Any breaking change - renaming an event, removing a field, changing the envelope shape - increments `schema_version` and lands with a documented migration in the CHANGELOG. Consumers should filter by `event` name and ignore unknown fields.

## What Is Not Public API

The following are internal and may change without notice in any release:

- Internal helper functions in `lib/*.sh`. Sourcing these from third-party code is unsupported; function names, argument order, and return-code semantics may change in any minor version.
- The on-disk byte layout of the two-file state beyond the documented JSON schema - compaction style, key order, whitespace, trailing newlines. Tools that diff or hash these files byte-wise will break.
- Anything in `tools/` other than `install.sh`. In particular, `verify-install.sh`, `uninstall.sh`, `cleanup-cron.sh`, `doctor.sh`, `query.sh`, `cost.sh`, `cost-compare.sh`, `calibrate-bytes-per-token.sh`, and `latency.sh` are convenience scripts whose flags, output format, and exit codes may change between minor versions.
- Archival file naming and directory layout under `$BATON_ARCHIVE_DIR`. Files land there; do not parse the names.
- The cleanup-cron cadence - currently every 2 days (`0 0 */2 * *`), may change without notice. Treat it as "eventually". (Distinct from the in-process `BATON_SWEEP_INTERVAL_HOURS` self-throttle.)
- The layout and naming of progress files under `$BATON_PROGRESS_DIR`. The `workstreams/<name>.json` pointer is the supported way to locate the current progress file.
- Test internals - fixtures, harness helpers, and the layout of `tests/`.
- Anything not explicitly listed in the four bullets at the top of this document.

## Extension Points (None Beyond Hooks)

> Pass the Baton does not have a plugin system, a hook-extension API, or a third-party storage backend. The Claude Code hook architecture is the extension surface. The four core-flow hooks (semver-protected) plus six observability hooks (additive contract) plus documented `BATON_*` environment variables plus the `hook-events.jsonl` schema are the entirety of the public API surface - there is no second extension mechanism. If you need behavior beyond what env vars provide, fork - the install script is one file, the runtime is ~1.7K LoC of bash, and PRs that generalize cleanly are welcome.

## Kill-Switch Watch

If Anthropic ships native percentage-triggered persistence (tracked at [anthropics/claude-code#18417](https://github.com/anthropics/claude-code/issues/18417)), Pass the Baton plans retirement with a documented migration to whatever the native primitive becomes. The repo will not silently rot - a retirement notice ships before the last release, and the migration path lands alongside it. "Documented migration" means: a step-by-step path from the current state-file layout and env-var surface to the native equivalent, with a script where mechanical translation is possible and a checklist where it isn't.
