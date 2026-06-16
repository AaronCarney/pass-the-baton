# Changelog

All notable changes to Pass the Baton are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project will adopt [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once `0.1.0` is cut.

---

## [Unreleased]

_No changes since the most recent pre-release entry below._

---

## [0.1.0-pre] - Pre-release history

The entries below predate the first tagged release. They document development work as it landed; section dates are landing dates, not release dates. Once `0.1.0` is cut, these will be retained under this anchor for provenance.

---

### Corpus-wide threshold-sweep aggregator (basic rigor) - 2026-05-22

#### New tool

- `tools/cost-sweep-corpus.sh` - runs the threshold counterfactual across a corpus of Claude Code transcripts; reports per-threshold median/mean/p95/IQR/count plus median-of-best-threshold and mode-of-best-threshold as the two independent typical-best statistics.

#### New libraries (sourced; not user-facing CLIs)

- `lib/corpus.sh` - transcript discovery + workspace include/exclude filter. Default excludes the `subagents/` workspace.
- `lib/sweep-aggregate.sh` - per-threshold summary statistics (median/mean/p95/IQR/count + mode-of-best). Pure bash + awk; no jq, no network.

#### Refactor (no behavior change for existing tools)

- `lib/cost-compare-model.sh` - added `ccmp::derive_prefix` and `ccmp::derive_summary_tokens_default`. These were previously inline in `tools/cost-compare.sh`; lifting them ensures byte-identical math between `cost-compare.sh` and the new aggregator. `tools/cost-compare.sh` now sources the lifted helpers; pre-existing test suite passes unchanged.

#### Schema posture

- The aggregator's JSON output schema is independent of `hook-events.jsonl`. It carries its own `schema_version: 1`. No new hook events; `hook-events.jsonl` schema_version remains 1, no bump.

#### Documentation

- `docs/cost-model.md` - new `## Corpus aggregator` section with usage, output schema, performance note, basic-rigor caveats, and pointer to the L0 intake doc.

#### Out of scope (deferred)

- Cross-method comparison (Anthropic `/compact`, auto-memory, `/clear`-only, do-nothing).
- Project-boundary primitive + time-to-complete metric.
- Confidence intervals, stratification keys, hierarchical models, power analysis.
- Per-transcript parallelization optimization.

---

### Multi-template progress-file system - 2026-05-21

Major feature epoch adding user-selectable progress-file templates, a
`/baton` dashboard skill, project-context resolution, and a block-and-retry
lint pipeline; the templates
themselves (`share/templates/`) are the authoritative format reference.

#### Added

- **Three built-in templates** under `share/templates/`: `free` (narrative,
  open-form), `task` (checkbox-driven task list with `[x]`-archive on write),
  and `factory` (structured epoch/task grid for plan-executor workflows). A
  `custom` path allows user-defined templates installed to
  `$XDG_CONFIG_HOME/baton/templates/`. Active template selected via
  `/baton set template=<name>`.

- **`/baton` dashboard skill** at `.claude/skills/baton/SKILL.md`.
  Supports `show` (display current config + active template) and
  `set key=value` (mutate global config). Managed keys: `template`,
  `threshold_pct`, `display_name`, `templates_dir`, `project_context_file`.

- **Project-context resolver** (`lib/project-context.sh`) maps semantic roles
  (PRD, architecture, decisions, …) to actual files via
  `.baton-project/project-context.json`. Falls back to naming-convention
  heuristics for projects without explicit config. Schema documented at
  `docs/project-context.md`.

- **Block-and-retry lint pipeline** (`lib/lints.sh`) on every checkpoint write.
  Three lint levels: V1 (Session Directive verbatim-match), V7 (per-section
  structural rules), V8 (placeholder-survivor regex). A lint failure blocks the
  write, emits a property-named retry message, and forces the model to
  re-render. No partial writes on lint failure.

- **Envelope versioning** (`template_id` + `template_version`) in the Task State
  JSON block of the `factory` template. Reserved for future migration-runner
  support; absent values treated as v1 per config-loader convention.

- **Template-resolve + template-render + rolloff libs** (`lib/template-resolve.sh`,
  `lib/template-render.sh`, `lib/rolloff.sh`) extracted as standalone modules
  with unit tests. These replace the prior monolithic checkpoint-write path.

#### Changed

- **Archive-not-delete rolloff convention** (Amendment 2026-05-21). Rolled-off
  entries move to `.baton/archive/<workstream>/<epoch>/` instead of being
  deleted. Aligns with Linear / GitHub Projects / Keep-a-Changelog convention.
  Epoch-boundary archive fires automatically when the model rotates to a new
  epoch marker.

- **`factory` template rolloff** uses per-checkpoint fresh-judgment: the model
  writes a complete `tasks_done` list each checkpoint containing only entries
  still load-bearing for the next session; omitted entries archive automatically.

- **`task` template rolloff** uses `[x]`-checkbox archive on write: completed
  items move to a `## Archived` section automatically, keeping the active list
  lean.

- **R3 locked directive** (Amendment 2026-05-21-B): the "What's Next" session
  directive block is now structurally locked - lint V1 enforces verbatim
  reproduction. Models may not paraphrase or shorten the directive.

- **`docs/context-baton.md`** no longer embeds the progress-file schema
  inline; format reference is now `share/templates/<name>.md` plus
  `share/templates/README.md` (the custom-template contract).

#### Deferred

- **Tag-based preservation system** (`feat` / `fix` / `decision` taxonomy with
  hybrid auto-first derivation per Conventional Commits). Considered and deferred
  2026-05-21 in favor of per-checkpoint fresh-judgment rolloff + archive-not-delete.
  Research baseline preserved (tag-taxonomy design). Revive triggers were
  recorded during development.

---

### Post-cycle hygiene - 2026-05-21

Three follow-ups landed after the multi-template cycle closed at code-review
iter-2. No API/schema changes.

#### Fixes

- **`9a4b682` - context-checkpoint honors v2 terminal binding (/resume rebinds).**
  Partial v2 migration had left `context-checkpoint.sh` reading the active
  workstream from the v1 POINTER→T_FILE chain while `checkpoint-write-trigger.sh`
  was already on the v2 `terminals/<term_hash>.json` path. `tools/resume.sh`
  rewrites the v2 record but does not touch POINTER, so a mid-session `/resume`
  left the PreToolUse hook emitting checkpoint paths under the OLD workstream
  while the PostToolUse write-trigger wrote under the NEW one - tripping the
  cross-workstream basename guard and rejecting the write. context-checkpoint
  now resolves workstream from `terminals/<hash>.json` first and falls back to
  POINTER→T_FILE only when the terminal record is absent (legacy sessions). The
  side-effect of marking `T_FILE.progress_file=pending` is preserved across
  both resolution paths. New test `V2-REBIND-CC` in `test-workstream-hooks.sh`
  pins the behavior.

- **`506f8d3` - template-resolve falls back to hook-lib's own repo.**
  The pre-fix precedence ended at `$PROJECT_DIR/share/templates/<id>.md`, which
  breaks the documented integrator pattern. Per
  `docs/integration-patterns.md` Pattern C, `$CLAUDE_PROJECT_DIR` is the
  consumer project, not the Pass the Baton repo - they are different directories.
  When hooks are consumed via a symlinked/sibling Pass the Baton repo (the
  intended integrator-audience layout), `$PROJECT_DIR` has no `share/` at all
  and the resolver returned a path to a non-existent file; empty scaffold files
  accumulated and `tpl::render_progress_file` silently no-op'd. Added rung 4:
  derive the lib's own repo location from `${BASH_SOURCE[0]}` and fall back to
  `<lib-repo>/share/templates/<id>.md`. Rung 5 (ultimate fallback) also moves
  from `$PROJECT_DIR` to the lib repo. Test fixture follow-on patched 4 tests
  whose stubs were passing only because the broken resolver made `lint::v1` a
  silent no-op on a missing file; also fixed `test-tools-changed.sh` T6's
  eval-via-variable assert that choked on shell metacharacters in the now-
  fully-rendered `additionalContext`.

- **`46c0a0d` - drop t8/t8b self-simulating scaffold tests.**
  Closes code-review Minor #7 by deletion. The two tests inline-copied the two
  lines of `checkpoint-write-trigger.sh`'s scaffold-cleanup logic and asserted
  against their own copy rather than driving the hook end-to-end; a regression
  in the real script's early-return ordering would not have fired. Promoting
  them to real contract tests would need 50-100 lines of fixture harness for
  two lines of production logic. Hook control flow is integration-tested by
  every real checkpoint trigger.

---

### Pre-public-ship hardening - 2026-05-18

Five small but user-visible fixes landed across the install/runtime/docs surfaces
during the pre-public-ship review loop. No new features, no API/schema changes.

#### Fixes

- **`fdf7fb5` - privacy: close chmod race on forensic event log.**
  `lib/workstream-lib.sh::log_event` now pre-creates `$BATON_DIR/hook-events.jsonl`
  under a subshell `umask 0177` before any append, mirroring the
  `envelope::emit` pattern. The file is mode 0600 from the first byte, eliminating
  the window where the trailing `chmod` could land after the first write under an
  inherited permissive umask.

- **`a50daeb` - portability: numeric-guard `date +%sN` captures.**
  `.claude/hooks/tool-timing.sh` and `.claude/hooks/checkpoint-write-trigger.sh`
  now regex-check `date +%sN` outputs before using them in arithmetic. BSD/macOS
  `date` leaves `+%N` literal in the captured string; the prior unguarded path
  tripped `set -u` on the non-numeric value and aborted the hook on every tool
  call.

- **`7c2df0d` - runtime defense: `flock(1)` shim.**
  `lib/envelope.sh` defines a no-op `flock` function if `flock(1)` disappears
  from `$PATH` after install (util-linux removed, PATH altered, etc.). Emits a
  one-time stderr nag so the degradation is visible. `tools/install.sh` still
  hard-fails without `flock`; this is belt-and-suspenders for post-install
  drift.

- **`fb3961d` - install/uninstall safety + canonical paths + test isolation.**
  - `tools/install.sh` inline `jq` now honors `$SETTINGS` everywhere (the prior
    inline path always wrote `${USER_SETTINGS:-$HOME/.claude/settings.json}`,
    bypassing `--settings`).
  - `.gitignore` append is now trailing-newline-safe (no longer concatenates the
    new entry onto an existing last line).
  - `tools/uninstall.sh` gains an opt-in `--target <dir>` flag for symmetric
    cleanup (removes `.baton/` from gitignore + cron wrapper + env file).
    **Behavior change:** uninstall is now soft by default (hooks/state only);
    pass `--target /path` for full per-repo cleanup. Soft default avoids
    rewriting unrelated repos when `uninstall.sh` is run from the wrong `$PWD`.
  - All `tools/*.sh` `REPO_DIR` derivations now use `pwd -P` for canonical paths.
  - `test-installer-nfs-warn.sh` isolates `HOME=$target`;
    `test-install-tools.sh` `INSTALL-MERGE-SETTINGS` count bumped 5→7;
    `test-installer-{post-tool-batch,tool-timing}.sh` switched from
    `USER_SETTINGS` to `SETTINGS`.

- **`26a8020` - docs accuracy: schemas + CLI references + counts.**
  - `docs/cost-model.md` `cost_rollup` + `cache_anomaly` example schemas
    rewritten to match the actual emit shape in `post-tool-batch.sh` (no more
    drift between docs and emission sites).
  - Every `Pass the Baton <subcmd>` reference across the doc tree (which
    described a binary that never existed) rewritten to `bash tools/<script>.sh`
    form matching the actual surface.
  - `docs/install.md` hook count 4 → 7 (three sites), test count 195/6 →
    722/30, uninstall section split into soft / `--target` modes.
  - `docs/context-baton.md` `BATON_WORKSTREAM_TTL_DAYS` default 14 →
    30 (the code says 30).

#### Docs

- `README.md` Privacy section + Repository Layout `envelope.sh` line now
  acknowledge that **two** files share the `hook-events.jsonl` basename -
  the structured telemetry log at `$XDG_STATE_HOME/baton/` and the
  project-local forensic audit log at `$BATON_DIR/`. `docs/telemetry.md`
  scopes itself to the first and points at `docs/context-baton.md` for the
  second.

#### Tests

Full suite: 30 / 0 (722 hard asserts) at the time of the install/uninstall
changes above. No new tests added in this pass; the existing suites were
updated to match the install/uninstall behavior changes.

#### Follow-on cleanup - 2026-05-19

- **Removed `tools/migrate-checkpoint-v2.sh` and its test.** The v1 layout
  was never publicly released - the migration tool exists only for
  internal pre-OSS state. The session-start.sh v1-state nudge,
  `docs/public-api.md` references (which listed migrate as part of the
  public surface), `docs/context-baton.md` Migration-from-v1 section
  and Files-table row, README repository-layout entry, and PREREQS test
  list have all been updated. **Public API surface shrinks** from
  `install.sh + migrate-checkpoint-v2.sh` to just `install.sh`.
- Three broken cross-doc anchors fixed in README.md and docs/public-api.md
  (`#environment-variables` → `#configuration-env-vars`,
  `#state-files` → `#state-layout`, `#layout-table` → `#files`).
- `.gitignore` collapsed the per-file research-notes entries to a
  glob; the stray `2026-05-16-academic-doc-dossier-prompt.md` was the
  only research artifact still tracked.
- `docs/context-baton.md` line 21 + Files-table row and
  `checkpoint-write-trigger.sh` header comment now reference
  `$BATON_PROGRESS_DIR/progress-*.md` (resolved at runtime by
  `checkpoint_progress_dir()` in `lib/workstream-lib.sh`) instead of the
  obsolete progress-files path. `docs/archive/` Files-table row
  replaced with `$BATON_ARCHIVE_DIR/<YYYY-MM>/` (the actual archive
  target).

Suite after follow-on cleanup: **all suites green after follow-on cleanup.**

---

### Event log, schema_version=1 - 2026-05-14

First-ever structured event log. Every hook invocation now writes a
machine-readable envelope to a local JSONL file; no network involved.

#### New files

- `.claude/hooks/lib/envelope.sh` - sole writer of `hook-events.jsonl`; enforces `schema_version=1`, mode 0600, 4 KiB size cap, CC8 redaction, torn-line safety, flock serialization.
- `.claude/hooks/lib/otel_mapping.sh` - OTel field-name reference (documentation only; not sourced at runtime).
- `tools/query.sh` - DuckDB-backed SQL query over live + rotated JSONL shards; degrades gracefully when DuckDB is absent (exit 2 + actionable message).
- `tools/doctor.sh` - health probe: resolves log path, checks FS type (NFS/CIFS warn), verifies mode 0600; exit 0 = clean.
- `share/logrotate.d/baton` - logrotate snippet: daily, 30-day retain, zstd compress, `su` override, `postrotate` reopen guard.
- `docs/telemetry.md` - operator reference: env vars, schema fields, NFS/flock guidance, rotation, privacy/CC8.

#### Modified hooks (T3 refactor)

All 4 hook scripts now route telemetry exclusively through `envelope::emit`
instead of ad-hoc appends:

- `.claude/hooks/context-checkpoint.sh` → emits `PreToolUse`
- `.claude/hooks/checkpoint-write-trigger.sh` → emits `PostToolUse`
- `.claude/hooks/session-start.sh` → emits `SessionStart`
- `.claude/hooks/project-detect.sh` → emits `UserPromptSubmit`

#### New env vars

| Variable | Default | Purpose |
|---|---|---|
| `BATON_EVENT_LOG` | `$XDG_STATE_HOME/baton/hook-events.jsonl` | Override log path |
| `BATON_EVENT_LOG_DISABLE` | `0` | Set to `1` to suppress all emission |

#### Schema baseline

```json
{
  "schema_version": 1,
  "event": "<PreToolUse|PostToolUse|SessionStart|UserPromptSubmit>",
  "ts": "<RFC-3339 UTC>",
  "data": { ... }
}
```

`schema_version=1` is the initial baseline. Future breaking changes will
increment this integer. Tools querying the log should filter or branch on
this field.

#### Tests added

8 new test files under `.claude/hooks/tests/`:
`test-envelope.sh`, `test-otel-mapping.sh`, `test-hook-writers.sh`,
`test-query.sh`, `test-doctor.sh`, `test-logrotate-snippet.sh`,
`test-installer-nfs-warn.sh`, `test-event-log-e2e.sh`

---

### Cost Estimator - 2026-05-14

Per-session cost breakdown from Claude Code transcripts. All computation
is local (no network); pricing is a bash-native PRICE table with a
freshness anchor.

#### New files

- `lib/cost-models.sh` - single source of truth for per-model pricing; exports `cost_models::price`, `cost_models::cost_of_turn`, `PRICING_VERIFIED_DATE`.
- `lib/tokens.sh` - byte→token estimator; model-specific bytes-per-token ratios.
- `tools/cost.sh` - reads a Claude Code transcript JSONL; flags `--session`, `--model`, `--self-check`, `--json`, `--last N`, `--geo`, `--fast`, `--verify --corpus`; prints USD breakdown with CC6 disclaimer.
- `tools/calibrate-bytes-per-token.sh` - count_tokens caller; writes ratios file.
- `.claude/hooks/post-tool-batch.sh` - PostToolBatch hook; reads transcript usage; emits `cost_rollup`; detects cache_creation doubling → emits `cache_anomaly`.
- `docs/cost-model.md` - operator reference: pricing primitives, geo/fast multipliers, calibration, CC6 disclaimer, privacy notes.

#### New hook events (schema_version remains `1` - additive)

| Event | Emitter | Purpose |
|---|---|---|
| `cost_rollup` | `post-tool-batch.sh` | Per-turn token usage snapshot |
| `cache_anomaly` | `post-tool-batch.sh` | Cache creation doubling detected (ratio ≥ 2×) |
| `tools_changed` | `context-checkpoint.sh` | File-change detection at PreToolUse (stub) |
| `prewarm_ok` | `session-start.sh` | Pre-warm succeeded at SessionStart |
| `prewarm_failed` | `session-start.sh` | Pre-warm failed at SessionStart |

**schema_version remains `1`.** All new events are additive; no existing
fields were removed or renamed. Tools querying the log should filter on
`event` name.

#### doctor.sh extensions

- `Cache anomalies (last 24h)` - counts `cache_anomaly` events within 24 h; emits `WARNING:` if any found.
- `Pricing freshness` - reads `PRICING_VERIFIED_DATE` from `lib/cost-models.sh`; emits `WARNING:` if age > 90 days.

#### Tests added

9 new test files under `.claude/hooks/tests/`:
`test-cost-models.sh`, `test-tokens.sh`, `test-calibrate.sh`,
`test-cost.sh`, `test-post-tool-batch.sh`, `test-anomaly-detector.sh`,
`test-tools-changed.sh`, `test-pre-warm.sh`, `test-cost-estimator-e2e.sh`

---

### Cost Estimator hardening - fix pass - 2026-05-15

Internal correctness pass over the E8 surface. No new commands; no schema
changes. User-visible behaviors that changed:

- **`tools/cost.sh`** - malformed transcript JSON no longer aborts the run; the bad line is warned and skipped. CC6 disclaimer text is now emitted verbatim from the spec. Pinned model-id alias derivation corrected. `--self-check` gained absolute price anchors instead of relative drift checks.
- **`tools/doctor.sh`** - default log path now resolved through the same logic as `envelope.sh` (was diverging in some `$XDG_STATE_HOME` configurations). Stale pricing now sets the `WARNED` status correctly (was silently passing); unset `PRICING_VERIFIED_DATE` no longer crashes the probe.
- **`tools/calibrate-bytes-per-token.sh`** - output numeric formatting is now locale-safe (`LC_ALL=C`). Per-type ratios are computed as true per-type medians rather than a pooled mean across types.
- **`.claude/hooks/post-tool-batch.sh`** - `cache_anomaly` boundary is inclusive at 2× (was strict-greater-than). The ephemeral-token usage field shape now matches the Claude Code transcript spec. `cost_rollup` writes use atomic read-modify-write via `flock` to prevent concurrent-emit truncation.
- **`.claude/hooks/session-start.sh`** - `prewarm_ok` envelope now includes the resolved pinned model id in addition to the requested alias.

Tests added: regression locks for each of the above (FIX-1/3/4 coverage, anomaly inclusive-2× boundary, `turn_index` payload, `tools_changed` payload assertions rather than mere presence).

#### Installer wiring - `project-detect.sh` registered (E7-T3 follow-up)

`project-detect.sh` (UserPromptSubmit hook, in the bundle since the initial release) was never registered by `tools/install.sh` or `tools/merge-settings.sh`. The script emitted `UserPromptSubmit` envelopes in E7-T3 but only fired in environments where users had manually edited their `~/.claude/settings.json`. `merge-settings.sh` now registers all five core hooks (SessionStart, PreToolUse, PostToolUse, SessionEnd, UserPromptSubmit), `verify-install.sh` checks for the new entry, and the matching installer test bumps from "4 hook entries" to "5 hook entries." User-visible effect: workstream `display_name` is now auto-populated from project-mention prompts (e.g., "let's work on my-app" → display_name "my-app") and from explicit `rename this session to X` prompts, instead of staying on the hash label.

---

### Cost-comparison analysis - 2026-05-16

A new analysis surface for reasoning about checkpoint-threshold trade-offs
and resume-pattern cache economics. Built as a delegation off `cost.sh`
without touching the E8 hard-floor (`lib/cost-models.sh`, `lib/tokens.sh`,
the E8-T8 subset of `tools/cost.sh`).

#### New files

- `lib/transcript.sh` - per-turn token stream reader. Emits TSV (`cache_read`, `cache_write_5m`, `cache_write_1h`, `fresh_input`, `output`) from a Claude Code transcript JSONL. CC8-safe (numerics only, no prompt/completion text); ephemeral-shape conditional mapping; corrupt-line and missing-file tolerant.
- `lib/cost-compare-model.sh` - pure economic model. Functions: `ccmp::uncached_total`, `ccmp::cached_total`, `ccmp::breakeven_turn`, `ccmp::threshold_sweep` (uncached→first-cached→cached state machine across configurable threshold percents), `ccmp::payoff_guards` (`single_turn`, `prefix_below_min`), `ccmp::summary_gen_cost` (Addendum A).
- `tools/cost-compare.sh` - CLI: `--transcript`, `--model`, `--summary-model`, `--summary-tokens`, `--json`, `--help`. Reports threshold-sweep across 20/28/40/never plus resume-pattern uncached vs cached (savings + breakeven turn). Reuses unchanged E8 engine for per-turn pricing.

#### `tools/cost.sh` extensions

- `--compare` - delegates to `cost-compare.sh` with passed-through args. E8 path is untouched when `--compare` is absent.
- `--distribution` - reports quantiles (p50/p90/p99) across `--last N` sessions (dossier §S7).

#### Addendum A - resume-summary generation cost

Models the per-`/clear` USD scalar for generating the resume summary, since
the summarizer model is often distinct from the session model. Default off;
opt in via flag or env var.

| Variable | Default | Purpose |
|---|---|---|
| `BATON_SUMMARY_MODEL` | session model | Pricing model for resume-summary generation |
| `BATON_SUMMARY_TOKENS` | `2500` | Token budget for resume-summary generation |

CLI: `cost-compare.sh --summary-model <id> --summary-tokens <n>`.

#### `lib/cost-models.sh` adjustments

- Opus 4.7 multiplier tightened against verified pricing source.
- Byte-per-token ratio bounds documented for cached-regime arithmetic.

#### New docs

- `docs/cost-model.md` §"Comparison analysis" - usage walkthrough for `--compare`, threshold-sweep interpretation, resume-payoff arithmetic.

#### Tests added

3 new test files under `.claude/hooks/tests/`:
`test-cost-compare-model.sh` (10 asserts), `test-cost-compare.sh` (23 asserts including e2e + production-threshold-sweep block), `test-transcript.sh` (4 asserts).

Full suite at close: **596 passed / 0 failed**. E8 hard-floor (252) unchanged.

---

### Latency observability + telemetry doc alignment - 2026-05-17

#### `docs/telemetry.md` rewrite (audit follow-up)

The shipped `docs/telemetry.md` documented a schema that did not match what
the envelope actually emitted. Rewrote against the emit sites:

- Removed 7 fictional fields: `schema`, `pct_context`, `route`, `directive_injected`, `progress_written`, `args_hash`, and the entire "common fields" block that no envelope writer produced.
- Replaced a misleading "p95 Bash latency over the last hour" example query that returned empty by construction (no `duration_ms` field existed anywhere in the emitted schema) with three working query examples against the real event types.
- Added a "What is not captured today" section to make deliberate gaps explicit rather than implied.

#### Opt-in per-tool latency hook

New `.claude/hooks/tool-timing.sh` (matcher `""`, all tools, registered by
`tools/install.sh`). **Off by default**; set `BATON_TIMING=1` to
enable. Fast off-path: env check then drain stdin and exit. Emits a
`tool_call` envelope with SDK-reported `duration_ms` plus self-measured
`hook_overhead_ms`.

| Variable | Default | Purpose |
|---|---|---|
| `BATON_TIMING` | `0` | Set to `1` to enable per-tool latency capture |

New event: `tool_call` (emitter `tool-timing.sh`) - per-tool duration + hook overhead.
**`schema_version` remains `1`** (additive).

#### New tool: `tools/latency.sh`

Quantile reporting over `hook-events.jsonl`. Four sections:

1. Per-tool latency (from `tool_call`)
2. Instrumentation overhead (from `hook_overhead_ms`)
3. Summarizer-window timing (PreToolUse `pending` → PostToolUse `progress` pairing)
4. Cleanup-hook duration

Flags: `--since-hours`, `--tool`, `--json`, `--include-shards`, `--help`.
POSIX awk quantile idiom shared with `cost.sh`; mktime via gawk with a
python3 fallback for mawk hosts.

#### Tests added

3 new test files: `test-tool-timing.sh` (20 asserts), `test-installer-tool-timing.sh` (11 asserts), `test-latency.sh` (40 asserts).

Full suite at close: **722 passed / 0 failed**.
