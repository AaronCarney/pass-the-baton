# Context Baton System

Automatic session handoff when Claude Code's context fills up. A workstream
record relays state between sessions; the per-terminal binding decides which
workstream a given session belongs to.

## Checkpoint Modes (governing definition)

Pass the Baton has two **modes**. The mode is a setting the user selects, not an
inference the system makes about the user: it is `auto_continue_mode`
(`/baton set auto_continue_mode=off|tmux|relaunch`). Nothing may try to *detect*
whether a person is present, or reason about why the user picked what they
picked - the setting is the only discriminator. That manual mode has a user in
the loop follows from the setting rather than being inferred from the session,
and it is precisely why a reminder has an addressee there and none in automatic
mode.

| | Mode 1 - Manual (`off`) | Mode 2 - Automatic (`tmux`, `relaunch`) |
|---|---|---|
| Who drives the handoff | the user | nobody, it is unattended |
| Reminder ("nag") | case 1A only | never |
| Who starts the new session | the user | the driver |

**Mode 1 is manual.** The user decides when the handoff happens. It has two
entry points, differing only in what triggers the checkpoint:

- **1A - threshold-fired.** The configured context threshold is crossed. The
  drain gate holds the write while subagents finish and return their results;
  the lead agent consolidates those results, in context or into a temp file;
  the progress file is written; the user is given a synopsis. **Only then** may
  the reminder begin. While it runs, user discussion aimed at understanding the
  current situation is allowed and is not treated as evasion. The
  continue-options window appears after the second user inquiry.
- **1B - `/pass-the-baton:renew`.** The user has already decided to refresh
  early, typically after pausing for a clarification or stopping a run of loops.
  Renew exists because `/clear` on its own skips the progress-file write that a
  threshold crossing would have produced. So renew writes the progress file and
  then does what `/clear` does: this session ends and a new one begins. There is
  no reminder and no keep-or-clear question, because invoking the command *is*
  the answer to that question.

**Mode 2 is automatic.** Threshold crossing, drain, consolidation, write, clear
and relaunch all happen with no user action, in both the tmux and the standalone
relaunch setups. The reminder has no addressee here and never fires.

**The reminder exists only in case 1A.** That is its entire scope. It is not a
budget, a counter, or an escalation to a deny.

> **Implementation status (2026-07-26).** The code does not yet match this
> definition. `context-checkpoint.sh:337` branches on `/tmp/baton-manual-<sid>`,
> which records *what armed the checkpoint* (`/renew` vs threshold), and never
> reads `auto_continue_mode`. The effect is that the reminder is absent from 1A,
> where it belongs, and present in 1B, where it cannot serve any purpose. The
> post-save keep-or-clear question is likewise attached to 1B instead of 1A.
> This section is the target; see CHANGELOG `[Unreleased]`.

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
   `$BATON_PROGRESS_DIR/progress-<workstream>-<term_hash>-<timestamp>.md`
   (resolved at runtime by `checkpoint_progress_dir()` in
   `.claude/hooks/lib/workstream-lib.sh`; default
   `$BATON_DIR/progress/`, see the env-var table below). The
   PreToolUse hook computes and injects the exact absolute path -
   Claude never has to derive it. The timestamp makes every checkpoint a new
   file on purpose: Claude Code refuses a Write that overwrites a file the
   session has not Read, so a reused destination cost a failed write plus a
   re-read of the stale progress file at the moment context is exhausted.
   Nothing in the old file is needed - the carry-forward is pre-rendered into
   the scaffold. The previous file is archived by step 4 rather than clobbered.
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

### While a checkpoint is owed but not yet written

Between step 2 (the trigger fires and sets pending) and step 3 (the progress
file lands), the checkpoint is **owed**. In that window each further tool call
carries the instruction to stop and write the progress file. That instruction
never gates, and it is not the reminder: there is no counter, no attempt limit,
and no escalation to a deny here, in either mode.

The reminder ("nag") is a **post-write** mechanism and does not live in this
window at all. It belongs to case 1A only, and it begins after the progress file
has landed and the user has been given the synopsis - at which point what it is
reminding them to do is hand off. See Checkpoint Modes above.

Two other mechanisms can still hold a tool call. Neither belongs to the reminder:

- The **drain gate** acts *inside* the owed window, before the write: it holds
  the parent's consequential tool calls - the progress write itself included -
  while subagents are still in flight, so nothing they are computing is lost from
  the checkpoint (read-only tools stay open; see the Subagent drain gate section
  below). Nothing outside the drain gate can hold a call before the progress file
  lands - every hold reachable in this window belongs to it, including the
  fail-closed denies it raises when its own libraries are missing. All of them
  exist to protect what goes into the checkpoint, not to enforce the reminder.
- The **DONE guard** acts *after* the window closes: it blocks every tool call
  once the write has landed, until you `/clear` (step 4).

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
  "progress_file": "/abs/path/to/progress-<ws>-<hash>-<ts>.md",
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
  "updated_at": "2026-05-09T13:30:00Z",
  "closed_at": "2026-05-09T14:05:00Z"
}
```

`closed_at` is an **additive optional** field: present once the terminal exits
cleanly (stamped by the SessionEnd hook), absent while the terminal is live.
Prompt-time leave-detection reads it to tell an attached co-tenant apart from
one that has already left; consumers must treat an absent `closed_at` as "live".

The `terminal_id` field stores the *source* string (`CLAUDE_TERMINAL_ID`, or
the tty / parent-shell tty fallback). The filename `terminals/<term_hash>.json`
is the **md5 hash** of `USER:<source>`, computed by
`lib/workstream-lib.sh::term_hash`.

### Session-scratch `/tmp` markers (internal)

These paths are **internal implementation detail**, listed here as a debugging
aid only. They are **not** a stability contract - external tooling must not
depend on their names, layout, or lifecycle, all of which may change without
notice. They describe the code as it stands today; `baton-manual-<sid>` and
`baton-consent-<sid>` both encode the superseded trigger-based split and will
change when the code is brought in line with Checkpoint Modes above.

- `/tmp/baton-subagents-active-<parent_sid>/<agent_id>` - one file per in-flight
  subagent; the directory listing is the active count. Written at SubagentStart,
  removed at SubagentStop, whole directory reaped by TTL sweep once the directory
  itself has been idle.
- `/tmp/baton-manual-<sid>` - marks the owed checkpoint as manually armed (via
  `/pass-the-baton:renew`). Created by `context-checkpoint.sh` when it consumes
  the force flag, removed by `checkpoint-write-trigger.sh` after a successful
  manual save.
- `/tmp/baton-consent-<sid>` - a manual checkpoint has been written and the user
  has not yet answered whether to keep working or clear. Created by
  `checkpoint-write-trigger.sh` on the manual path in place of the DONE latch,
  consumed by `tools/baton-consent.sh`. Answering `keep` also clears
  `/tmp/claude-context-triggered-<sid>` so the threshold re-arms; `clear` latches
  `/tmp/baton-done-<sid>` instead.
- `/tmp/baton-unlock-<sid>` - present means checkpointing is off for this session.
- `/tmp/baton-snooze-<sid>` - contents are an absolute expiry epoch;
  checkpointing resumes once it passes.

## Three Execution Modes

| Behavior            | Interactive (default)              | Subagent (`agent_id` in hook input)            | Autonomous (`AGENT_SESSION_ID` set) |
|---------------------|-------------------------------------|-------------------------------------------------|-------------------------------------|
| Checkpoint trigger  | 20% → inject save workflow          | Reads parent's PCT via `term_hash` → "wrap up" | No-op (SDK wrapper handles)         |
| Save protocol       | Full (progress file → cleanup)      | None - parent runs after subagent returns      | SDK wrapper handles                 |
| Progress injection  | SessionStart auto-injects directive | N/A                                             | SDK wrapper passes initial context  |
| Post-checkpoint     | Block all tool calls                | Not blocked - the parent holds its own write until the subagent returns (drain gate) | N/A                                 |

### Subagent bridging

Subagents (Agent tool) get a different `session_id` from the parent and can't
read the parent's PCT directly. Bridge:

1. SessionStart writes the parent's `session_id` to
   `/tmp/claude-parent-sid-${TERM_HASH}` (keyed on `CLAUDE_TERMINAL_ID`).
2. PreToolUse in the subagent detects `agent_id` → reads the parent's
   `session_id` from the terminal-keyed file → reads the parent's PCT.
3. At 20%: a one-shot "wrap up" warning. The subagent is never blocked - instead
   the PARENT's checkpoint write is held until every subagent returns, so nothing
   in flight is lost. See the drain gate section below.
4. PostToolUse cleanup is skipped entirely for subagents - the parent runs the
   save protocol after the subagent returns.

### Subagent drain gate

When a checkpoint comes due while subagents are still running, writing the
progress file immediately would capture a snapshot that is missing whatever they
are still computing. So the checkpoint WRITE is held, not the subagents.

While any subagent is in flight, the parent's consequential tool calls (including
the progress write itself) are denied with `Checkpoint write held: N subagent(s)
still running`. Read-only tools stay open so you can keep orienting. Once the last
subagent returns, the write proceeds with their results folded in.

If a subagent runs longer than `BATON_DRAIN_TIMEOUT_SECS` (default 360) you are
asked whether to write the checkpoint without it. Allow discards anything that
subagent has not yet returned; Deny keeps waiting.

This requires the `SubagentStart` hook to be registered, and it ships through two
channels. Plugin installs register it in `hooks/hooks.json` - check with
`jq -e '.hooks.SubagentStart' hooks/hooks.json`. Installer (`tools/install.sh`)
installs register it through `tools/merge-settings.sh` into
`~/.claude/settings.json`; if the check above comes back empty after upgrading,
re-run `tools/install.sh` to pick up the new wiring. Until it is registered in the
channel your install uses, the gate silently does nothing.

## Switching Workstreams

A terminal's binding lives only in `terminals/<term_hash>.json`. To change it:

- **At launch:** set `WORKSTREAM=<name>` before invoking `claude`. SessionStart
  validates the name (`^[a-zA-Z0-9_-]+$`), creates the workstream record if it
  doesn't exist, and writes the binding.
- **Mid-session:** reopen the session with `claude --resume` to reacquire the
  same workstream (same session_id). For an intentional switch to a different
  workstream, rewrite the binding in `terminals/<term_hash>.json` to point at
  the target workstream id; the next checkpoint write picks up the new binding.

`WORKSTREAM=<name> claude` at launch is the supported explicit switch.

### Co-tenancy

Multiple terminals may attach to the same workstream. SessionStart injects a
roster snapshot NOTE when more than one terminal is attached, and
UserPromptSubmit surfaces a set-diff notice when the attached set changes -
so a co-tenant is always visible, never silent. `max_terminals_per_workstream`
(env `BATON_MAX_TERMINALS_PER_WORKSTREAM`, default 0 = unlimited) caps
accidental auto-joins: a **bare project mention** over the cap is hard-blocked,
while an **explicit `WORKSTREAM=`** over the cap soft-overrides with a warning
(the explicit request wins). The shared workstream record holds a single
progress pointer, so concurrent co-tenant checkpoints are **last-writer-wins** -
the last checkpoint to write the record owns the pointer.

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
| `BATON_MAX_TERMINALS_PER_WORKSTREAM` | `0` | Opt-in co-tenancy cap: max terminals that may auto-join one workstream. `0` = unlimited. Bare-mention auto-joins over the cap are hard-blocked; an explicit `WORKSTREAM=` over the cap soft-overrides with a warning. |
| `BATON_DRAIN_TIMEOUT_SECS` | `360` | Seconds before an unfinished subagent is treated as hung and the drain offers to write the checkpoint without it. Measured from subagent start, so this is total elapsed runtime, not idle time - raise it above your longest realistic subagent. |
| `BATON_SNOOZE_MAX_MIN` | `120` | Upper bound on `/pass-the-baton:snooze [minutes]`. Deferring longer is a decision to stop checkpointing; use `/pass-the-baton:off` for that. |
| `BATON_WORKSTREAM_TTL_DAYS` | `30` | Days before a workstream record is archived. |
| `BATON_TRACKING_TTL_DAYS` | `7` | Days before a per-session tracking pointer is reaped. |
| `BATON_PROGRESS_COLD_DAYS` | `7` | Days an archived progress file stays in the readily-accessible recent tier before the cleanup cron moves it to cold storage. Age is read from the write timestamp embedded in the filename, not from mtime. |
| `BATON_TMP_TTL_HOURS` | `24` | Age before `/tmp` stragglers are swept by the cleanup cron. |
| `BATON_SWEEP_INTERVAL_HOURS` | `48` | Self-throttle interval for the cleanup sweep (the `--if-due` gate in `cleanup-cron.sh`). **Does not set cron frequency** - `install-cron.sh` prints a fixed `0 0 */2 * *` crontab line (every two days); this var only gates whether an invoked sweep actually runs. |
| `BATON_CRON_LOG` | `$HOME/.cache/baton/cron.log` | Where the cleanup cron writes its log. |
| `BATON_DISPLAY_NAME` | (auto-generated) | Optional human-readable label for this terminal's workstream. Read at `claude` launch time. |
| `BATON_AUTO_CONTINUE` | `0` | Legacy tmux enable flag. Set to `1` and run inside tmux to arm the tmux auto-continue driver; any other value or no tmux leaves it off. Acts as the default the mode selector consults when no mode is set at any layer. |
| `BATON_AUTO_CONTINUE_MODE` | `off` | Auto-continue driver selector: `off`, `tmux`, or `relaunch`. Resolved env > `config.json` `auto_continue_mode` > default `off`; an unrecognized value resolves to `off`. |
| `BATON_AUTO_CONTINUE_NUDGE` | `proceed` | tmux driver: the text sent after `/clear` to start the next session working on the injected progress. |
| `BATON_AUTO_CONTINUE_LOG` | `${TMPDIR:-/tmp}/baton-auto-continue.log` | tmux driver: audit log of every committed injector action (`continued`, `cleared-not-continued-prompt-timeout`, `fail-*`). |
| `BATON_AUTO_CONTINUE_BIN` | `tools/baton-auto-continue.sh` | tmux driver: override path to the injector binary (test/advanced seam). |
| `BATON_RELAUNCH_MAX` | `10` | relaunch driver: cap on relaunches per `baton-run` invocation. A non-numeric value falls back to `10` rather than uncapping. |
| `BATON_RELAUNCH_LOG` | `${TMPDIR:-/tmp}/baton-relaunch.log` | relaunch driver: audit log of every committed relaunch action (`armed`, `relaunch`, `stop-*`). |
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

**Auto-continue notes.**

- The `baton` launch alias now honors the selected `auto_continue_mode` driver (`tmux` or `relaunch`), not relaunch-only.
- `/pass-the-baton:renew` fires a manual early checkpoint on demand, running the same save-and-handoff path as a threshold crossing.

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
│   └── YYYY-MM/                                # month the file was ARCHIVED, not written
│       └── progress-<ws>-<hash>-<writets>.md   # checkpoint-write-trigger.sh
├── progress-cold/
│   └── YYYY-MM/                                # the same archive month, carried over by the move
│       └── progress-<ws>-<hash>-<writets>.md   # cleanup-cron.sh Block 5
└── checkpoint-state/
    └── YYYY-MM/
        ├── workstreams/<ws>.json               # workstream-lib.sh::archive_workstream
        └── sessions-tracking/<sid>.json        # workstream-lib.sh::archive_session_tracking
```

Note the two roots: **progress** markdown archives under
`$BATON_ARCHIVE_DIR/progress/YYYY-MM/` (written directly by the post-write
trigger), while **workstream** records and **per-session tracking** files
archive under `$BATON_ARCHIVE_DIR/checkpoint-state/YYYY-MM/{workstreams,sessions-tracking}/`
(written by the rolloff helpers).

Progress archives are two-tier. A checkpoint's superseded progress file lands in
`progress/YYYY-MM/`; once its embedded write timestamp is older than
`BATON_PROGRESS_COLD_DAYS` (default 7), the cleanup cron moves it to
`progress-cold/YYYY-MM/`. The move is a plain `mv` with no compression, so both
tiers are readable by the same tools, and the source partition is preserved.
Archived filenames carry exactly one timestamp: the write time, which the
basename already holds. A legacy basename written before per-checkpoint naming
carries none, so the archiver appends one - that is the only case where the
archive time appears in a name.

The `YYYY-MM` partition is the month the file was **archived**, not the month it
was written: the archiver derives it from the clock at archive time, not from the
basename. The two differ for any file written near a month boundary, or archived
long after it was written. The cold-tier move preserves whichever partition the
file was already in rather than recomputing one, so `progress-cold/YYYY-MM/`
carries that same archive month.

A known archived (idle >7d) workstream id can be restored with `tools/restore-workstream.sh <ws-id>`; there is no longer a built-in command to list archived records. Restoring an archived workstream searches **both** progress archive tiers - `progress/YYYY-MM/` and `progress-cold/YYYY-MM/` - and copies the record back to `$BATON_DIR/workstreams/` and the progress file back to `$BATON_PROGRESS_DIR/`.

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
| `tools/cleanup-cron.sh`                            | Yes | 48h sweep - `/tmp` stragglers, two-tier progress archive, dead workstreams. |
| `tools/repair-event-log.sh`                        | Yes | Backup-first repair - rewrites the event log dropping malformed lines (CC20). |
| `$BATON_DIR/workstreams/<ws>.json`            | No (ephemeral) | Workstream record (progress file pointer + display name + phase). |
| `$BATON_DIR/terminals/<hash>.json`            | No (ephemeral) | Per-terminal binding to a workstream.                              |
| `$BATON_DIR/hook-events.jsonl`                | No (gitignored) | Forensic audit log written by `log_event`.                       |
| `$BATON_PROGRESS_DIR/progress-*.md`           | No (ephemeral) | Current progress (hybrid MD + JSON). Default `$BATON_DIR/progress/`. |
| `$BATON_ARCHIVE_DIR/progress{,-cold}/<YYYY-MM>/` | No (gitignored) | Archived progress files, recent and cold tiers. Default `$HOME/.local/share/baton/`. |

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
