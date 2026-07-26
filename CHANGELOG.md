# Changelog

All notable changes to Pass the Baton are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as of `0.3.0`.

---

## [Unreleased]

## [0.5.0] - 2026-07-25

### Added

- **Subagent drain gate: a checkpoint no longer writes while subagents are still
  running.** Previously the parent wrote its progress file the moment the
  threshold was crossed, capturing a snapshot that was missing whatever the
  in-flight subagents were still computing, and the subagents themselves were
  hard-blocked once the parent's DONE flag went up. That is inverted: the
  subagents run to completion and the parent's checkpoint WRITE is what waits.
  While any subagent is in flight the parent's consequential tool calls are
  denied with `Checkpoint write held: N subagent(s) still running`; read-only
  tools stay open. Once the last one returns, the write proceeds with their
  results folded in. If a subagent outruns **`BATON_DRAIN_TIMEOUT_SECS`**
  (default `360`, measured from subagent start, so total elapsed runtime rather
  than idle time) you are asked whether to write without it: Allow discards
  whatever it has not returned, Deny keeps waiting. The gate depends on the
  `SubagentStart` hook being registered - see the Fixed entry below - and does
  nothing silently until it is.

- **`/pass-the-baton:off` and `/pass-the-baton:snooze [minutes]`.** Two escapes
  from an owed checkpoint that do not require arguing with the nag. `off`
  disables the entire checkpoint lifecycle for the current session (no trigger,
  no gate, no nag) until you start a new one. `snooze` defers it, default 10
  minutes, bounded by **`BATON_SNOOZE_MAX_MIN`** (default `120`) on the grounds
  that a longer deferral is really a decision to stop checkpointing, which is
  what `off` is for. Snoozing with a checkpoint already owed warns that it
  defers the reminder and not the obligation.

- **Manual checkpoints ask for consent after the save, not before each tool
  call.** A checkpoint armed with `/pass-the-baton:renew` now writes its progress
  file first and asks the user once, afterward, whether to keep working or clear -
  replacing the earlier menu that prompted on every consequential tool call before
  anything was saved. When the manual save lands, the model reports a brief
  synopsis and asks "Keep working in this session, or clear now?", then stops;
  nothing is blocked while the user decides, because the progress file is already
  on disk. The answer is resolved by `tools/baton-consent.sh`: `keep` clears the
  session's trigger flag so the threshold re-arms for the next crossing, while
  `clear` latches the done flag and hands off (the user is told to `/clear`). The
  outstanding-consent marker is reaped at `SessionEnd` and by the cron TTL sweep,
  so a question left unanswered never wedges the session.

- **Manual checkpoints emit a handoff synopsis.** After a `/renew` save
  completes, the model reports in 2-4 sentences what state was captured, which
  workstream and progress file it landed in, and the single next action the
  handoff points at. Threshold-fired checkpoints do not do this - nobody is
  there to read it.

- **Interactive tabbed dashboard: `baton-dashboard.sh tui`.** Four panes -
  Status (live context fill, threshold, auto-continue mode, whether a checkpoint
  is owed), Config, History, Workstreams. Falls back to plain `show` when there
  is no TTY, so scripted and piped callers are unaffected.

- **`BATON_SWEEP_INTERVAL_HOURS` is now visible and settable from the
  dashboard.** It appears in `show` with its effective source and accepts
  `baton-dashboard.sh set BATON_SWEEP_INTERVAL_HOURS=<n>` like the other TTLs.

### Changed

- **BREAKING: tty-derived terminal hashes are now salted with the kernel boot id.**
  The `term_hash` tiers that derive from a tty (the fallback path taken when
  `CLAUDE_TERMINAL_ID` is unset) now fold in the kernel boot id, so a tty device
  name recycled across a reboot can no longer bind a resumed session to a previous
  boot's workstream. The explicit `CLAUDE_TERMINAL_ID` tier is unchanged. This is a
  breaking change to the terminal-hash filename convention published in
  [`docs/public-api.md`](docs/public-api.md), so the release that ships it takes a
  **major** version bump (the release process assigns the number; this lands under
  `[Unreleased]`). Migration: no action required, but every terminal-keyed artifact
  rekeys exactly once on the first hook fire after upgrading -
  `$BATON_DIR/terminals/<hash>.json` and `/tmp/claude-parent-sid-<hash>`. Old
  files are orphaned rather than read, reaped by
  `tools/cleanup-cron.sh` on normal TTL. Live sessions re-resolve through the
  session-id path `session-start.sh` owns. Within a single boot nothing moves.

- **Threshold-fired checkpoints no longer nag.** An automated checkpoint has no
  user in the loop, so the interactive escalation that guarded it (a per-tool-call
  counter at `/tmp/baton-nag-<session>`, a `pending-unsatisfied` event per attempt,
  and a hard `deny` once the counter crossed `_CC_NAG_LIMIT`) applied an
  interactive device to a non-interactive path: it could trap a model with no way
  to answer the prompt. The automated path now emits the checkpoint write
  instruction and nothing else, at any attempt count. Telemetry is de-escalated
  rather than dropped: the per-attempt `pending-unsatisfied` is replaced on this
  path by a non-escalating `pending-automated` event, one per owed tool call with
  no counter, so the owed-checkpoint signal survives without the escalation. **Manual checkpoints armed via
  `/pass-the-baton:renew` still emit the reminder**, because a human is there to
  read it - that is now the whole of the difference from the automated path,
  whose emitted text is identical and which is told apart only by its telemetry
  event (`pending-manual` on the manual path, `pending-automated` on the
  automated one). The pre-tool-call consent menu the manual path once
  carried was already replaced by the post-save consent flow described above. The
  never-written-checkpoint signal is likewise unaffected: `cleanup-on-exit.sh`
  still records `abandoned-pending` when a checkpoint outlives its session
  undelivered.

### Fixed

- **The relaunch driver replayed session-selection flags, so a checkpoint
  relaunch parked on the session picker.** The supervisor loop re-ran the
  original argv on every iteration, so a terminal launched as `baton --resume`
  met the interactive picker instead of continuing, and `baton --resume <id>` or
  `baton --continue` would have re-entered the very session the checkpoint had
  just handed off from. `-r`, `--resume`, `-c` and `--continue` now apply to the
  first launch only and are dropped from every relaunch; `--resume` consumes a
  following session id only when one is present, so `--resume --model opus`
  keeps `--model`. Every other argument still passes through untouched.

- **`tools/install.sh` never actually installed the cron wrapper.** Step 7
  invoked `tools/install-cron.sh --dry-run`, which by contract writes nothing, so
  the `BATON_*` answers the installer collects and exports for it - the archive
  directory among them - reached a child that discarded them, and neither the env
  file nor the wrapper was ever created. It now runs for real. This does not
  touch your crontab: `install-cron.sh` only ever prints the line to paste, in
  every mode, and `uninstall.sh` already removes the env file and wrapper.

- **`SubagentStart` was not registered in either install channel, so nothing
  that depends on it ran.** Plugin installs now declare it in
  `hooks/hooks.json`; `tools/install.sh` installs merge it into
  `~/.claude/settings.json` through `tools/merge-settings.sh`. Verify with
  `jq -e '.hooks.SubagentStart' hooks/hooks.json`, and re-run `tools/install.sh`
  after upgrading if your install uses the settings channel.

- **The tmux auto-continue nudge could be typed into the prompt and never
  sent.** `/clear` rides a single atomic `send-keys` and submitted fine, but the
  nudge has to split into a literal-text send plus a separate `Enter`, and with
  no gap between them the `Enter` raced Claude Code's input debounce and landed
  before the text committed - leaving the nudge sitting unsent in the box and
  the session stalled after the clear. A settle delay now separates the two,
  tunable via `_AUTO_CONTINUE_NUDGE_SETTLE` (default `0.5` seconds).

- **A checkpoint that was owed could block the very reads the checkpoint workflow
  mandates.** The workflow tells the model to read the active template and the
  pre-rendered scaffold and compose the progress file from them, but the only
  exemption while a checkpoint was owed covered the `progress-*.md` write. The model
  could not reach its required input, reconstructed the Session Directive from
  memory, and validation rejected the imperfect copy: an unrecoverable deadlock.
  Reads of `*.scaffold.md` and of the resolved active template are now exempt
  while a checkpoint is owed, so the composition step can reach its inputs.

- **The owed-checkpoint reminder can no longer hold a tool call before the
  progress file is written.** The escalation and its per-tool-call counter are
  gone from BOTH the automated and the manual path: the reminder is now just a
  reminder, with no attempt limit and no `deny` at any call count. This closes
  the deadlock class the exemption above only narrowed - because the reminder no
  longer gates before the write, the read/write exemption list (the `progress-*.md`
  write and the scaffold/active-template reads) is no longer what keeps the save
  reachable; it now only suppresses the reminder on the checkpoint's own tool
  calls. Two denies remain, both outside this change: the **drain gate** holds
  consequential tool calls (the write included) while subagents are still in
  flight, leaving read-only tools open, and the **DONE guard** blocks every tool
  call after the checkpoint has been written, until you `/clear`.

---

## [0.4.0] - 2026-07-22

### Added

- **`baton` launch alias.** Opt in at install (the 6th setup prompt) or with `/baton set launch_alias=<name>`, then launch Claude with `baton` instead of `claude`. The alias follows your configured auto-continue driver and writes a marker-guarded alias block to your shell rc.
- **Auto-continue drivers via `auto_continue_mode`** (`off` / `tmux` / `relaunch`). `tmux` drives `/clear` + a continue nudge into the pane after a checkpoint; `relaunch` runs a fresh-session supervisor loop. Select with `/baton set auto_continue_mode=...`; the installer seeds `relaunch` as the default only when no driver is already configured (a preselected `tmux`, including the legacy `BATON_AUTO_CONTINUE=1`, is preserved).
- **`/pass-the-baton:renew` fires a checkpoint on demand.** Run it to save-and-hand-off immediately, before the context-fill threshold is reached - useful when you want to end a session cleanly at a natural stopping point. It runs the identical checkpoint path as an automatic threshold crossing and is independent of the reported context percentage.

---

## [0.3.3] - 2026-07-20

The "no silent handoffs" release: every way a checkpoint could fail to save now either blocks or leaves a record. Previously several of them did neither, and the session looked saved when it was not.

### Fixed

- **A checkpoint that fails to register now stops the session instead of waving it through.** When the workstream pointer could not be written, the hook emitted an advisory note that the tool protocol discards, so the model went on to tell you the checkpoint was saved and to `/clear`. It now blocks, as the other two failure paths already did.
- **An interrupted checkpoint no longer goes silent while context stays above the threshold.** If the checkpoint turn was cut short, the trigger fired once and then went quiet for the rest of the session - the save was still owed but nothing said so. The hook now re-fires on each following tool call and, if the checkpoint is still unsaved after several attempts, escalates to a hard block.
- **A session that ends with a checkpoint still owed is recorded** as `abandoned-pending` in the event log, instead of being swept away with no trace.
- **A malformed context percentage no longer disables checkpointing in silence.** A statusline emitting `20.5` or `20%` instead of `20` now surfaces the health warning naming the offending value, rather than exiting quietly on every tool call.
- **Carry-forward of the previous progress file works again.** The lookup searched a hardcoded directory that ignored `BATON_PROGRESS_DIR`, plus an archive path nothing writes to, so the `Archived` section silently rendered empty. It could also select a leftover scaffold over the real file.
- **The scaffold can no longer be registered as the handoff**, and a leftover scaffold no longer wins the carry-forward lookup.
- **Blocked tool calls now explain themselves** instead of reporting a bare `Blocked by hook`.
- **A template switch is now scoped to this terminal's own checkpoint, fully closing E4.** `baton-dashboard.sh set template=...` used to glob every `/tmp/baton-pending-*` flag on the host, so a live checkpoint in another terminal - or a leftover marker from a crashed session - refused the switch for every project on the machine until the marker aged out. It now keys on THIS terminal's resume-stable `session_id`: the switch is refused only when this session's own `/tmp/baton-pending-<session_id>` flag exists alongside a fresh pct sibling inside the mode-dependent liveness window. Another terminal's in-flight checkpoint no longer blocks you, and a `claude --resume` reconnect still blocks its own owed checkpoint.
- Archive failures are recorded rather than swallowed; the rollover lookup now picks the newest prior progress file instead of the alphabetically-first; and the workstream display name no longer blanks on the record-absent path.

---

## [0.3.2] - 2026-07-16

The "clean resumes" release: a second, tmux-free way to hand off between checkpointed sessions, and `claude --resume` no longer replays a checkpoint over a transcript that already has it.

### Added

- **Fresh-relaunch auto-continue driver** (opt-in, off by default): a second way to hand off between checkpointed sessions, alongside the existing tmux driver - neither is the default, pick whichever fits. Launch `tools/baton-run.sh` instead of `claude` (args pass through) and set `BATON_AUTO_CONTINUE_MODE=relaunch`; after a checkpoint the session exits at the turn boundary and a fresh `claude` starts in the same terminal with the progress file re-injected - no tmux, no keystroke injection. A wrapper is required because no hook can end a session from the inside. Bounded by `BATON_RELAUNCH_MAX` (default `10`) and audited to `BATON_RELAUNCH_LOG`. See `docs/configuration.md`.
- **`BATON_AUTO_CONTINUE_MODE`** (`off`|`tmux`|`relaunch`, default `off`) selects the auto-continue driver; settable via `baton-dashboard.sh set auto_continue_mode=...`. An unrecognized value resolves to `off` so a typo cannot arm a driver. **`BATON_AUTO_CONTINUE=1` continues to mean tmux, unchanged**, for anyone who has not set a mode.

### Fixed

- **`claude --resume` no longer re-injects the progress file.** Resuming a session restores its full transcript, so injecting the checkpoint on top of it replayed stale instructions the session had already moved past. SessionStart now injects only on the `startup`/`clear` paths and prints a one-line note on `resume`, where the context is already present.
- The per-checkpoint `.relaunch-fired` marker is now swept on session exit, so it cannot outlive its checkpoint.

---

## [0.3.1] - 2026-07-13

The "co-tenancy safety" release: a bare project mention no longer hijacks an established terminal, attached terminals are surfaced instead of silent, and an opt-in cap bounds how many terminals share a workstream.

### Added

- **Opt-in co-tenancy cap** `max_terminals_per_workstream` (env `BATON_MAX_TERMINALS_PER_WORKSTREAM`, default `0` = unlimited): caps how many terminals may auto-join a single workstream. A bare project mention over the cap is hard-blocked; an explicit `WORKSTREAM=` over the cap soft-overrides with a warning.
- **Roster visibility**: SessionStart injects a snapshot NOTE when more than one terminal is attached to a workstream, and SessionStart/UserPromptSubmit surface a set-diff notice when the attached set changes, so a co-tenant is never silent. Terminal records now carry an additive optional `.closed_at` stamp written on a clean exit (present = left cleanly, absent = live), enabling prompt-time leave-detection.

### Changed

- **Bare project mention no longer force-rebinds an established terminal.** A bare mention now rebinds the terminal to an existing same-named workstream only when the current workstream is fresh (never checkpointed); an established terminal keeps its binding and prints a `WORKSTREAM=<target> claude` switch hint instead of silently switching.

---

## [0.3.0] - 2026-07-12

The "friction-free continuity" release: crash recovery, same-terminal auto-continue, an honest settings dashboard, and every checkpoint policy value single-sourced.

### Added

- **Same-terminal auto-continue** (opt-in, off by default): set `BATON_AUTO_CONTINUE=1` and, in a tmux session, a checkpoint save now drives `/clear` plus a continue nudge into your pane automatically - no manual keystrokes between checkpointed sessions. Tunable via `BATON_AUTO_CONTINUE_NUDGE` (default `proceed`) and audited to `BATON_AUTO_CONTINUE_LOG`. Outside tmux, or unset, it is a clean no-op. See `docs/configuration.md`.
- **User-extensible Key Files roles**: `.baton-project/project-context.json` now takes a registry that merges over the six built-in roles, so you can override a role's path/label or add a brand-new role type (surfaced as an injected Key Files pointer) with no code edit. Role values accept the pre-existing string-path shorthand or an object (`path`/`label`/`hint`/`convention`/`order`). See `docs/project-context.md`.
- **Crash recovery via session-id reacquisition**: on `claude --resume` in a new terminal (binding lost after a crash/reboot), the session is reattached to its workstream by matching the `session_id` stamped on the record, before any fresh mint. `/clear` still resolves by terminal hash and never consults session_id.

### Changed

- **Checkpoint default threshold is now 20% context fill (was 23%)**, single-sourced as `BATON_DEFAULT_PCT_THRESHOLD`. Override with `BATON_PCT_THRESHOLD`.
- **Dashboard shows each key's effective source.** `baton-dashboard.sh show` now annotates every row with `[env]` / `[config]` / `[default]` so a configured value is never confused with a compiled default.
- E2 cross-path command reachability: `install.sh` now installs the kept skills (`baton`, `install-baton`) into the target's `.claude/skills/`, fixing manual installs that previously yielded zero slash commands; `uninstall` removes them. Removed the superseded `/resume` skill and `tools/resume.sh` - use native `claude --resume` with automatic session_id reacquisition. Docs now name the plugin's namespaced `/pass-the-baton:baton`. Note: removing `/resume` also removed the only enumerator of archived/idle workstreams; `tools/restore-workstream.sh` restores a record but needs a known workstream id (there is no built-in id discovery for archived records).
- Adaptive threshold tuner now runs automatically: each session start runs one controller cycle, gated on event collection being on (open arc or `BATON_COLLECT=1`); a no-op under the placeholder `score_hold` until a real scoring function is configured.
- `tuner_snapshot` telemetry event: each main session records the resolved threshold-tuner knob vector (setpoint, deadband, step, safety bounds, dwell, scoring fn) plus the effective threshold and `session_id`, gated on event collection. Lets a knob setting be joined to its session's `cost_rollup` from the logs alone.

### Fixed

- Cron uninstall now removes the exact schedule install writes. The cleanup-cron cadence is single-sourced (`0 0 */2 * *`, every 2 days); previously `uninstall` matched a stale `0 */48 * * *` that could fail to remove the installed line.

---

## [0.1.0-pre] - Pre-release history

The entries below predate the first tagged release (`0.3.0`). They document development work as it landed; section dates are landing dates, not release dates. They are retained under this anchor for provenance.

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
