# Project Arcs (cost envelopes)

A **project arc** is a marked run of one project under one continuation method.
Collection is **off by default**: with no arc open and no global collect flag
set, no event is written at all. Marking the run wires `tools/project.sh` into
the event data plane - it *opens collection* for the marked terminal: every
event emitted while the arc is open is written and stamped with the run's
identity, and `tools/cost.sh --arc <slug>` reads the run total back off those
stamps. The unit measured is the **envelope** - one `(slug, method)` pair - and
its membership is determined *solely* by the start/end markers.

## The envelope

An envelope is one marked run of one project under one method. Its identity is
the pair `(slug, method)`:

- **slug** - the project name you pass to `mark-start`.
- **method** - the continuation-method arm label (see below).

Membership is marker-bounded: everything emitted in the marked terminal between
`mark-start` and `mark-end` belongs to the envelope, and nothing else does.
There is no time window, no cwd heuristic, no automatic detection - the two
markers are the only thing that defines the run. Markers are placed by hand;
crashes are not detected (if a session dies mid-arc, the arc is still open until
you run `mark-end`).

## Marking an arc

```
tools/project.sh mark-start <slug> [--method LABEL]
tools/project.sh mark-end   <slug> --status success|abandoned|paused [--note TEXT]
```

`--method LABEL` records the continuation-method arm - the strategy used to keep
working as context fills. It is a free-form string captured as its own field in
the arc state file, alongside slug, workstream, and description. The canonical
labels are:

| Label | Meaning |
|---|---|
| `baton` | Pass the Baton's deferred handoff |
| `/compact` | Claude Code's built-in context compaction |
| `auto-memory` | auto-memory continuation |
| `/clear-only` | `/clear` with no handoff aid |
| `none` | single session, no continuation event |

`--method` is optional for ad-hoc tracking, but **benchmark runs MUST pass
`--method`** - the arm label is half the envelope identity, and an unlabelled run
cannot be compared across methods.

## Single active arc per terminal

A terminal owns at most one open arc. A second `mark-start` on the same terminal
is refused while an arc is open; close the current one with `mark-end` first.
This keeps attribution unambiguous - there is never a question of which arc an
event belongs to.

## Terminal/session-scoped attribution

Attribution keys on `terminal_id`, not `session_id`. Every event emitted from the
marked terminal while the arc is open is stamped with `project_slug` + `method`,
**across whatever sessions occur in that span.** A run that spans a checkpoint, a
`/compact`, or a `/clear` keeps accruing into the same envelope: the new session
inherits the terminal's open arc, so its events carry the same `(slug, method)`
stamp. Token-usage records roll up `session_id → envelope` - one terminal owns
the run, but it may host many sessions over the run's life, and the envelope
total is the sum across all of them.

Workstream id is still captured on every event (existing convention) but is *not*
the aggregation key.

## Sub-agent spend is included

PostToolBatch reads only the *main* session transcript, so a Task-tool
sub-agent's token spend never surfaced through it. A dedicated `SubagentStop`
hook (`.claude/hooks/post-subagent-cost.sh`) closes that gap: on each sub-agent
exit it reads the sub-agent's own last `usage` block from its transcript and
emits a `cost_rollup` through the same stamping emitter (`lib/envelope.sh`),
which auto-stamps the open arc's `project_slug` + `method` for the inherited
`CLAUDE_TERMINAL_ID`. Both hooks share one token extractor
(`.claude/hooks/lib/usage-tokens.sh`), so all five fields (`cache_read`,
`cache_write_5m`, `cache_write_1h`, `fresh_input`, `output`) are preserved
identically; sub-agent events carry a `source:"subagent"` discriminator.
Per-arc totals therefore include sub-agent token spend, not just the lead
session's.

> **Caveat (live end-to-end).** The mechanism is in place and unit-tested, but
> the full multi-agent path has not yet been spot-checked on a live controlled
> run. Treat live sub-agent attribution as provisional until you have verified it
> against the emitted `source:"subagent"` events in your own setup.

## Reading the total

```
tools/cost.sh --arc <slug>
```

`--arc` filters the event log to the events stamped with that slug, then the
existing cost engine prices them. The report preserves the **five-field token
breakdown** - `cache_read`, `cache_write_5m`, `cache_write_1h`, `fresh_input`,
`output` - rather than collapsing to a single dollar figure, and reports **both
raw token totals and raw USD**. Each turn is priced per-model
(`lib/cost-models.sh`), so mixed-model runs price correctly and the total is
re-priceable if rates change. It is a pure addition to the existing query path -
no new storage.

## Collection is off by default

Collection is gated, not always-on. `lib/envelope.sh` writes an event only when
**collection is open**, which happens when either condition holds:

- an arc is open for this terminal (the marker is the gate - the normal path), or
- the global collect flag is set (`BATON_COLLECT=1`, env var or the
  `BATON_COLLECT` key in `config.json`, settable via the `/baton`
  dashboard).

With neither an open arc nor the collect flag, **no event is written at all** -
not merely unstamped. There is no background collection; the default fresh
install collects nothing until you open an arc or enable collection.

`BATON_EVENT_LOG_DISABLE=1` is a **hard kill-switch**: it short-circuits
emission in `lib/envelope.sh` ahead of the gate, so it overrides even an open
arc - no events are written, nothing is stamped, and `--arc` reports nothing for
runs made while it was set.

## Round-trip example

```
# 1. Mark the start of the run, with its method arm.
$ tools/project.sh mark-start dashboard-refactor --method baton
project: started dashboard-refactor (workstream=main-20260608-1042)

# 2. Work. The open arc has turned collection on for this terminal, so events
#    - including any sub-agent cost_rollups - are written and stamped
#    (slug=dashboard-refactor, method=baton) as they emit.
#    The run may cross a checkpoint or /clear; it keeps accruing.

# 3. Mark the end.
$ tools/project.sh mark-end dashboard-refactor --status success --note 'shipped at sha abc123'
project: ended dashboard-refactor (status=success)

# 4. Read the envelope total.
$ tools/cost.sh --arc dashboard-refactor
baton cost - arc dashboard-refactor (method=baton)
─────────────────────────────────────────────────────
cache_read            1843200 tok    $0.5530
cache_write_5m         204800 tok    $0.7680
cache_write_1h              0 tok    $0.0000
fresh_input             51200 tok    $0.7680
 output                 38400 tok    $2.8800
─────────────────────────────────────────────────────
TOTAL                          $4.9690
```

See [`docs/context-baton.md`](context-baton.md) for the marker →
event-stamping flow, and [`docs/projects.md`](projects.md) for the full
`tools/project.sh` CLI (exit codes, `list`, `show`, the opportunistic
auto-prompt).
