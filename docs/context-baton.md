# Context Baton System

Automatic session handoff when Claude Code's context fills up. A workstream
record relays state between sessions; the per-terminal binding decides which
workstream a given session belongs to.

## How It Works

1. The **statusline** writes the current context % to
   `/tmp/claude-context-pct-${SESSION_ID}` on every refresh.
2. The **PreToolUse hook** (`context-checkpoint.sh`) reads that value on every
   tool call. At the configured threshold (default 20; resolved env >
   `config.json` > default and bounds-checked to 1-99 by
   `workstream-lib.sh::checkpoint_threshold`, which both the gate at
   `context-checkpoint.sh:66,158` and the telemetry `threshold` field read -
   so trigger and reported value never diverge - see the env-var note below):
   - Lists this terminal's progress files for archival (matched by `term_hash`)
     into `/tmp/baton-archive-${SESSION_ID}`.
   - Sets `/tmp/baton-pending-${SESSION_ID}`.
   - Injects the full save-progress workflow into Claude's next turn,
     including the exact path to write and a pointer to this doc for the
     format schema.
   - One-shot per session (the trigger flag prevents re-fire).
3. Claude reads this doc, then writes the progress file at exactly
   `$BATON_PROGRESS_DIR/progress-<workstream>-<term_hash>.md`
   (resolved at runtime by `checkpoint_progress_dir()` in
   `.claude/hooks/lib/workstream-lib.sh`; default
   `$BATON_DIR/progress/`, see the env-var table below). The
   PreToolUse hook computes and injects the exact absolute path -
   Claude never has to derive it.
4. The **PostToolUse hook** (`checkpoint-write-trigger.sh`, matcher
   `Write|Edit|MultiEdit`) fires when Claude writes any `progress-*.md`
   while a checkpoint is pending:
   - Validates the basename contains the bound workstream id (cross-workstream
     guard).
   - Atomically updates `workstreams/<ws>.json` with `progress_file` and
     `updated_at` (under `flock`).
   - Archives the files listed at PreToolUse, skipping the one just written.
   - Sets `/tmp/baton-done-${SESSION_ID}`. Subsequent tool calls
     are blocked by the PreToolUse hook until the user `/clear`s.
5. **No commit is required.** State transfers the moment Claude writes the
   progress file. Claude *may* commit the progress file for git durability;
   the commit is not load-bearing.
6. On the next session (`startup`, `clear`, `resume`, `compact`), the
   **SessionStart hook** (`session-start.sh`) resolves the terminal's
   `term_hash`, reads `terminals/<hash>.json` for the bound workstream,
   reads `workstreams/<ws>.json` for the latest progress file, and injects
   it as a mandatory directive ("this is your assignment, follow it"). New
   terminals with no binding get a fresh auto-created workstream named
   `<branch>-YYYYMMDD-HHMMSS-<hash6>`.
7. The **UserPromptSubmit hook** (`project-detect.sh`) watches prompts for a
   project mention or "rename this session to X" and updates the bound
   workstream's `display_name`.
8. For crash recovery, reopen the session with `claude --resume`; the terminal
   binding is re-established automatically (session_id reacquisition). If the
   workstream cannot be reacquired, a fresh workstream is minted.

## Progress File Format

Progress files are rendered from a user-selectable **template** at `share/templates/<name>.md`. Three templates ship with Pass the Baton:

| Template | When to use | Reference |
|---|---|---|
| `free` | Unstructured Claude Code use; prose-only session notes | `share/templates/free.md` |
| `task` | Semi-structured project work outside a formal L1/L2 plan | `share/templates/task.md` |
| `factory` | Full software-factory workflow with L1/L2 plan awareness and JSON Task State | `share/templates/factory.md` |

Users may also install custom templates at `$XDG_CONFIG_HOME/baton/templates/<name>.md`. See `share/templates/README.md` for the placeholder convention, section-manifest sidecar format, and minimum-required-section contract.

The active template is selected via `/baton set template=<name>` (see `.claude/skills/baton/SKILL.md`).

### Why hybrid markdown + embedded JSON

The `factory` template carries a JSON Task State block embedded in markdown prose. This split is intentional:

- **Anthropic's own production harness** (Nov 2025 "Effective harnesses for long-running agents") uses the exact same hybrid split - `feature_list.json` for structured task state, `claude-progress.txt` for free-form session notes. Direct current-generation precedent.
- **Constrained-decoding** (Structured Outputs, Nov 2025 launch on Sonnet 4.5+, Opus 4.5+, Haiku 4.5) largely fixed the syntactic JSON failure modes that drove the original 3.5-era prose-vs-JSON concern.
- **Prose-outside-JSON has no escape mechanics** - no `\n`, no `\"` overhead. Model writes natural prose without per-character mental cost.
- **Production failure reports on long structured outputs persist** in 4.x (Kibana #256563, agno-agi #2128, Opus 4.7 changelog noting 4.6 "drops rules" on long structured outputs). The hybrid format isolates the durable-state portion (JSON) while the bulk lives in forgiving markdown.

### Validation pipeline

Progress-file writes trigger a lint pipeline (V1, V7, V8) enforced by `.claude/hooks/checkpoint-write-trigger.sh`. On lint failure, the write is blocked with a property-named retry message; the model fixes and re-writes.

| Lint | Target | Failure message |
|---|---|---|
| V1 | Session Directive verbatim copy | Names the directive-drift property and points the model back at the active template's directive section |
| V7 | Section-specific structural lints (file:line in What's Next, Branch/HEAD in Position, JSON entry shape in Task State) | Names the underlying property (e.g., "the What's Next section must reference specific files…") not the lint field name |
| V8 | Placeholder-survivor regex (`<<[A-Z_]+>>`) | Reports the unfilled placeholder tokens and tells the model to write a literal value (e.g., "None") rather than leave the placeholder |

## State Layout

Two files - no overlapping fields, no fallback paths.

### `$BATON_DIR/workstreams/<ws>.json`

The workstream record. One file per workstream, overwritten in place.

```json
{
  "workstream": "main-20260509-131955-653278",
  "display_name": "my-project",
  "progress_file": "/abs/path/to/progress-<ws>-<hash>.md",
  "phase": "implementation",
  "updated_at": "2026-05-09T13:30:00Z"
}
```

### `$BATON_DIR/terminals/<term_hash>.json`

The per-terminal binding. The single source of truth for "which workstream
does this terminal belong to."

```json
{
  "terminal_id": "<CLAUDE_TERMINAL_ID-or-tty>",
  "workstream": "main-20260509-131955-653278",
  "updated_at": "2026-05-09T13:30:00Z"
}
```

The `terminal_id` field stores the *source* string (`CLAUDE_TERMINAL_ID`, or
the tty / parent-shell tty fallback). The filename `terminals/<term_hash>.json`
is the **md5 hash** of `USER:<source>`, computed by
`lib/workstream-lib.sh::term_hash`.

## Three Execution Modes

| Behavior            | Interactive (default)              | Subagent (`agent_id` in hook input)            | Autonomous (`AGENT_SESSION_ID` set) |
|---------------------|-------------------------------------|-------------------------------------------------|-------------------------------------|
| Checkpoint trigger  | 20% → inject save workflow          | Reads parent's PCT via `term_hash` → "wrap up" | No-op (SDK wrapper handles)         |
| Save protocol       | Full (progress file → cleanup)      | None - parent runs after subagent returns      | SDK wrapper handles                 |
| Progress injection  | SessionStart auto-injects directive | N/A                                             | SDK wrapper passes initial context  |
| Post-checkpoint     | Block all tool calls                | Block all tool calls (parent's DONE flag)      | N/A                                 |

### Subagent bridging

Subagents (Agent tool) get a different `session_id` from the parent and can't
read the parent's PCT directly. Bridge:

1. SessionStart writes the parent's `session_id` to
   `/tmp/claude-parent-sid-${TERM_HASH}` (keyed on `CLAUDE_TERMINAL_ID`).
2. PreToolUse in the subagent detects `agent_id` → reads the parent's
   `session_id` from the terminal-keyed file → reads the parent's PCT.
3. At 20%: a one-shot "wrap up" warning. If the parent's DONE flag is set:
   hard block.
4. PostToolUse cleanup is skipped entirely for subagents - the parent runs the
   save protocol after the subagent returns.

## Switching Workstreams

A terminal's binding lives only in `terminals/<term_hash>.json`. To change it:

- **At launch:** set `WORKSTREAM=<name>` before invoking `claude`. SessionStart
  validates the name (`^[a-zA-Z0-9_-]+$`), creates the workstream record if it
  doesn't exist, and writes the binding.
- **Mid-session:** reopen the session with `claude --resume` to reacquire the
  same workstream (same session_id). For an intentional switch to a different
  workstream, rewrite the binding in `terminals/<term_hash>.json` to point at
  the target workstream id; the next checkpoint write picks up the new binding.

## Project Arcs (cost envelopes)

A marked run (`tools/project.sh mark-start <slug> [--method LABEL]` →
`mark-end`) wires into the event data plane. `project.sh` writes the arc state
file (`terminal_id` + `method`); while the arc is open, `lib/envelope.sh`
resolves the open arc for the current terminal and stamps `project_slug` +
`method` onto every event it emits - terminal/session-scoped, so a run that
spans a checkpoint or `/clear` keeps accruing into one envelope. `tools/cost.sh
--arc <slug>` reads those stamps back to report the run total (incl. sub-agent
spend). Full reference: [`docs/arc.md`](arc.md).

### The event log is off by default

`envelope::emit` (`lib/envelope.sh`) - the writer behind the
`hook-events.jsonl` data plane - is **gated, not always-on**. It writes an
event only when collection is open: when **an arc is open** for this terminal
(the marker is the normal gate) **or** the `BATON_COLLECT` flag is set
(env var, or the verbatim `BATON_COLLECT` key in `config.json`, settable
via the `/baton` dashboard (invoked as `/pass-the-baton:baton` when installed
as a plugin)). With neither, no event is written - a fresh
install collects nothing until the user opens an arc or enables collection.
`BATON_EVENT_LOG_DISABLE=1` is a hard kill-switch ahead of the gate that
suppresses emission even when an arc is open.

Checkpoint continuity (resume / workstream binding / progress files) is
**unaffected** by this gate: it runs off the two-file state under
`$BATON_DIR/` (`workstreams/`, `terminals/`) and the progress markdown,
not the JSONL event log. Gating the observability log never disables a
checkpoint or a resume.

## Configuration (env vars)

| Variable | Default | Purpose |
|---|---|---|
| `BATON_DIR` | `$PROJECT_DIR/.baton` | Where workstream + terminal state lives. |
| `BATON_PROGRESS_DIR` | `$BATON_DIR/progress` | Where progress markdown files are written. |
| `BATON_ARCHIVE_DIR` | `$HOME/.local/share/baton` | Where archived (>7d-idle) workstreams move. |
| `BATON_PROJECT_DIR` | `$PWD` at install time | Project root for cron (cron has no `$PWD`). |
| `BATON_PCT_THRESHOLD` | `20` | Percent context-fill trigger. Resolved **env var > `config.json` `threshold_pct` > default 20** by `workstream-lib.sh::checkpoint_threshold`, then bounds-checked: an integer in **1-99** is honored, anything else falls back to 20. Both the gate (`context-checkpoint.sh:66,158`) and the telemetry `threshold` field read through that one function, so changing this var (or `threshold_pct` in config) moves the actual trigger. |
| `BATON_WORKSTREAM_TTL_DAYS` | `30` | Days before a workstream record is archived. |
| `BATON_TRACKING_TTL_DAYS` | `7` | Days before a per-session tracking pointer is reaped. |
| `BATON_TMP_TTL_HOURS` | `24` | Age before `/tmp` stragglers are swept by the cleanup cron. |
| `BATON_SWEEP_INTERVAL_HOURS` | `48` | Self-throttle interval for the cleanup sweep (the `--if-due` gate in `cleanup-cron.sh`). **Does not set cron frequency** - `install-cron.sh` prints a fixed `0 0 */2 * *` crontab line (every two days); this var only gates whether an invoked sweep actually runs. |
| `BATON_CRON_LOG` | `$HOME/.cache/baton/cron.log` | Where the cleanup cron writes its log. |
| `BATON_DISPLAY_NAME` | (auto-generated) | Optional human-readable label for this terminal's workstream. Read at `claude` launch time. |
| `WORKSTREAM` | (unset) | Explicit binding. Corrupt referenced JSON exits 1; missing fresh-creates. |
| `BATON_COLLECT` | `0` | Global override that opens event-log collection with no arc. Env var, or the verbatim `BATON_COLLECT` key in `config.json` (set via the `/baton` dashboard). |
| `BATON_EVENT_LOG_DISABLE` | `0` | Hard kill-switch - suppresses all `envelope::emit` output, overriding even an open arc. |
| `BATON_TUNE_SETPOINT` | `0` | Adaptive-tuner target score (score-space, may be fractional). Placeholder default - owner sets the real value from data. Resolved env > `config.json` `tune_setpoint` > default. |
| `BATON_TUNE_DEADBAND` | `1` | Tolerance band around the setpoint; the tuner holds while \|score − setpoint\| ≤ deadband. Placeholder. `tune_deadband`. |
| `BATON_TUNE_STEP` | `2` | Threshold step size in percentage points per applied adjustment. Placeholder. `tune_step`. |
| `BATON_TUNE_SAFETY_MIN` | `10` | Lower bound the tuner will never set the threshold below. Placeholder. `tune_safety_min`. |
| `BATON_TUNE_SAFETY_MAX` | `50` | Upper bound the tuner will never set the threshold above. Placeholder. `tune_safety_max`. |
| `BATON_TUNE_DWELL_SECONDS` | `86400` | Minimum seconds between applied adjustments (rate-limit). Placeholder. `tune_dwell_seconds`. |
| `BATON_TUNE_SCORE_FN` | `score_hold` | Name of the scoring function the tuner uses. The default `score_hold` is a guaranteed no-op (returns the setpoint, so every cycle decides HOLD). `tune_score_fn`. |

**config.json wiring (CC6).** The `/baton` dashboard persists every variable above to
`config.json`. Most consumers read through `_cfg::get` (`lib/config.sh`), honoring
**env var > `config.json` > default** precedence; legacy keys whose env name differs
from their JSON key (e.g. `BATON_PCT_THRESHOLD` <-> `threshold_pct`) pass the JSON key
as `_cfg::get`'s third argument. A per-consumer audit splits the keys three ways, and
the dashboard's `show` output tags each row accordingly so you can see whether a `set`
will take: **env-honored** keys (the majority) tag `[env]`/`[config]`/`[default]`;
**config-only** keys (`template`, `templates_dir`, `project_context_file`) whose
authoritative consumer reads `config.json` directly and ignores the env var tag
`[config-only]` and display their value config-direct; and the
**env-only-by-design** locators tag `[env-only by design]`. `BATON_DIR` and
`BATON_PROJECT_DIR` stay env-only by design (they locate the state dir / install
root before config can be read). When you need a value to take effect
everywhere, export the env var - it always wins.

## Adaptive threshold tuner (built, not yet connected)

The checkpoint threshold has a closed-loop feedback controller
(`lib/threshold-controller.sh`, E-C). One control cycle measures a score,
compares it to the setpoint, and - if outside the deadband - steps the threshold
by one `BATON_TUNE_STEP` within the `[BATON_TUNE_SAFETY_MIN, BATON_TUNE_SAFETY_MAX]`
band, rate-limited by `BATON_TUNE_DWELL_SECONDS`, persisting via the same
`_cfg::set threshold_pct` write the dashboard uses. An exported
`BATON_PCT_THRESHOLD` hard-pins the threshold and suppresses the tuner.

It auto-runs once per **main** session from `session-start.sh` (the subagent
path exits before this block), and only while event collection is on (an open
arc or `BATON_COLLECT=1`) - never silently in an ordinary session.

**It does not optimize anything yet, by design.** The scoring function is a
swappable registry entry, and the shipped default `score_fn=score_hold` returns
the setpoint, so `decide` always chooses HOLD and `apply` never writes - every
auto-tick is a guaranteed no-op. More importantly, no scoring function is wired
to the measurement signals the system already produces (the summary-tokens
running mean, `cost_rollup` events, the outcome proxies, or `tools/recommend.sh`).
Until a real `score_*` reads one of those signals and the owner sets real knob
values, the controller is a complete *mechanism* with no *feedback*. The
`tuner_snapshot` and `threshold_applied` events it emits (see
[telemetry](telemetry.md)) record its knob vector and any apply, but nothing
consumes them today.

Legacy `OLORIN_*` vars (`OLORIN_PROJECT_DIR`, `OLORIN_ARCHIVE_DIR`) are accepted as fallbacks for one release cycle with a deprecation warning. See [`docs/install.md`](install.md) for first-time setup.

## Archive Layout

Pruned workstreams move to:

```
$BATON_ARCHIVE_DIR/
├── progress/
│   └── YYYY-MM/
│       └── progress-<basename>.md        # checkpoint-write-trigger.sh
└── checkpoint-state/
    └── YYYY-MM/
        ├── workstreams/<ws>.json         # workstream-lib.sh::archive_workstream
        └── sessions-tracking/<sid>.json  # workstream-lib.sh::archive_session_tracking
```

Note the two roots: **progress** markdown archives under
`$BATON_ARCHIVE_DIR/progress/YYYY-MM/` (written directly by the post-write
trigger), while **workstream** records and **per-session tracking** files
archive under `$BATON_ARCHIVE_DIR/checkpoint-state/YYYY-MM/{workstreams,sessions-tracking}/`
(written by the rolloff helpers).

A known archived (idle >7d) workstream id can be restored with `tools/restore-workstream.sh <ws-id>`; there is no longer a built-in command to list archived records. Restoring an archived workstream copies the record back to `$BATON_DIR/workstreams/` and the progress file back to `$BATON_PROGRESS_DIR/`.

## Files

| File                                              | Tracked | Purpose                                                              |
|---------------------------------------------------|---------|----------------------------------------------------------------------|
| `~/.claude/statusline.sh`                          | No (global) | Writes context % to `/tmp/claude-context-pct-${SESSION_ID}`.       |
| `.claude/hooks/context-checkpoint.sh`              | Yes | PreToolUse - configured-threshold trigger (default 20%), save-workflow injection, post-DONE block.    |
| `.claude/hooks/checkpoint-write-trigger.sh`        | Yes | PostToolUse (`Write|Edit|MultiEdit`) - atomic cleanup on progress write. |
| `.claude/hooks/session-start.sh`                   | Yes | SessionStart - workstream binding + progress directive injection; runs one adaptive-tuner cycle + emits tuner_snapshot when collection is on (main session only).      |
| `.claude/hooks/project-detect.sh`                  | Yes | UserPromptSubmit - project-name + rename-prompt → `display_name`.      |
| `.claude/hooks/cleanup-on-exit.sh`                 | Yes | SessionEnd - archive per-session tracking, wipe `/tmp` for known SIDs. |
| `.claude/hooks/post-tool-batch.sh`                 | Yes | PostToolBatch - `cost_rollup` from the main session's last `usage`.    |
| `.claude/hooks/post-subagent-cost.sh`             | Yes | SubagentStop - `cost_rollup` (`source:"subagent"`) from the sub-agent's own transcript (`agent_transcript_path`, not the parent's `transcript_path`). |
| `.claude/hooks/lib/usage-tokens.sh`                | Yes | Shared 5-field token extractor for both cost-rollup hooks.             |
| `lib/eventlog.sh`                                  | Yes | Tolerant event-log reader (`eventlog::stream` - drops malformed lines via `jq -cR 'fromjson? // empty'`) (CC20). |
| `.claude/hooks/lib/workstream-lib.sh`              | Yes | Shared helpers: `term_hash`, `derive_display_name`, `log_event`, prune. |
| `tools/cleanup-cron.sh`                            | Yes | 48h sweep - `/tmp` stragglers, archive rotation, dead workstreams.     |
| `tools/repair-event-log.sh`                        | Yes | Backup-first repair - rewrites the event log dropping malformed lines (CC20). |
| `$BATON_DIR/workstreams/<ws>.json`            | No (ephemeral) | Workstream record (progress file pointer + display name + phase). |
| `$BATON_DIR/terminals/<hash>.json`            | No (ephemeral) | Per-terminal binding to a workstream.                              |
| `$BATON_DIR/hook-events.jsonl`                | No (gitignored) | Forensic audit log written by `log_event`.                       |
| `$BATON_PROGRESS_DIR/progress-*.md`           | No (ephemeral) | Current progress (hybrid MD + JSON). Default `$BATON_DIR/progress/`. |
| `$BATON_ARCHIVE_DIR/<YYYY-MM>/`               | No (gitignored) | Archived progress files (>7d-idle workstreams). Default `$HOME/.local/share/baton/`. |

## Troubleshooting

### Trigger never fires

The checkpoint trigger is driven by the statusline shim writing `/tmp/claude-context-pct-${SESSION_ID}`. If a session burns past 20% without the checkpoint hook running, the statusline shim is not being invoked.

```bash
# Verify the shim is wired into Claude Code's statusline command:
grep -q baton-pct.sh ~/.claude/settings.json && echo "OK" || echo "MISSING"

# Check the per-session tick file exists:
ls -lt /tmp/claude-context-pct-* 2>/dev/null | head -3

# Confirm the hook is firing at all:
jq -c 'select(.event=="checkpoint")' "$BATON_DIR/hook-events.jsonl" | tail -5
```

### Progress file not archived after checkpoint

The post-write trigger archives the previous session's progress only when it detects the `pending` flag set by the pre-tool-use hook. If the trigger received the write but rejected the path:

```bash
jq -c 'select(.event=="basename-reject")' "$BATON_DIR/hook-events.jsonl" | tail -10
```

Common cause: progress filename does not match `progress-*.md`. The literal `progress-` prefix is part of the contract - see [`docs/integration-patterns.md`](integration-patterns.md) "Filename contract" note.

### Wrong workstream injected at SessionStart

Terminal-to-workstream binding is two files: `terminals/<term_hash>.json` points at a workstream id; `workstreams/<ws>.json` is the record.

```bash
TH=$(USER=$USER CLAUDE_TERMINAL_ID=$CLAUDE_TERMINAL_ID \
     bash -c 'source .claude/hooks/lib/workstream-lib.sh; term_hash')
cat "$BATON_DIR/terminals/${TH}.json"
cat "$BATON_DIR/workstreams/$(jq -r .workstream "$BATON_DIR/terminals/${TH}.json").json"
```

If the binding points at a workstream id you don't recognize, reopen with `claude --resume` to reacquire the intended workstream.
