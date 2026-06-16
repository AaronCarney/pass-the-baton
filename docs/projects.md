# Project boundaries

Pass the Baton emits `project_boundary` events at the start and end of a discrete body of work - a *project* - so downstream analyses (cost per completed project, time-to-complete, cross-method comparison) can aggregate above the session level.

## Why

Claude Code sessions are too small to be a useful aggregation unit, and workstreams are unbounded. A project is the natural in-between: a discrete piece of work with a clear start and a clear end. Marking these boundaries unblocks per-project cost rollups, time-to-complete metrics, and outcome-quality proxies.

## CLI usage

```
tools/project.sh mark-start <slug> [--description TEXT]
tools/project.sh mark-end <slug> --status success|abandoned|paused [--note TEXT]
tools/project.sh list [--active|--all]
tools/project.sh show <slug>
```

The workstream and terminal id come from the `CLAUDE_WORKSTREAM` and `CLAUDE_TERMINAL_ID` environment variables (set by the SessionStart hook).

### Examples

```
$ tools/project.sh mark-start nightly-refactor --description 'pull audit-helpers out of cost-models.sh'
project: started nightly-refactor (workstream=main-20260520-1730)

$ tools/project.sh mark-end nightly-refactor --status success --note 'shipped at sha abc123'
project: ended nightly-refactor (status=success)

$ tools/project.sh list --active
# (empty)

$ tools/project.sh show nightly-refactor
{
  "slug": "nightly-refactor",
  "started_at": "2026-05-20T17:30:12Z",
  "ended_at": "2026-05-20T22:14:55Z",
  "status": "success",
  "workstream": "main-20260520-1730",
  "description": "pull audit-helpers out of cost-models.sh",
  "notes": ["shipped at sha abc123"]
}
```

### Exit codes

- `0` - success
- `1` - argument error: missing required slug, unknown flag, missing `--status` on mark-end, disallowed status enum value
- `2` - state error: no such project (mark-end / show on unknown slug), double-start (mark-start on existing slug)

Scripts that consume `tools/project.sh` should distinguish rc=1 (programmer error - usage bug) from rc=2 (recoverable - project doesn't exist).

## Opportunistic auto-prompt

When the SessionStart hook fires and the current workstream has had no active project marker for >= 7 days (measured from the most recent project's `started_at`, not file mtime), Pass the Baton surfaces a one-line nudge in the session's additionalContext:

> *No active project marker. Run tools/project.sh mark-start <slug> to start tracking per-project economics.*

The nudge is a prompt, never an auto-emit. Manual override always wins.

Two semantic notes on the threshold:
- **Brand-new workstreams** (no project state files at all for this workstream) get the nudge on the first session - `idle_days` returns a sentinel large value when no projects match.
- **`started_at`, not `ended_at`** - a project that ran 30 days and ended 2 days ago counts as 30 days idle, not 2. A long-running project doesn't reset the counter when it ends. This is intentional (the nudge tracks "time since you last started tracking", not "time since you stopped working") but can surprise.

## Event shape

Project boundaries emit `project_boundary` events via `envelope::emit`. The envelope stamps the top-level `schema_version`; the per-event payload lives in `data`.

Start event:

```json
{
  "schema_version": 1,
  "event": "project_boundary",
  "ts": "2026-05-20T17:30:12Z",
  "data": {
    "slug": "nightly-refactor",
    "kind": "start",
    "workstream": "main-20260520-1730",
    "terminal_id": "term-abc",
    "description": "pull audit-helpers out of cost-models.sh"
  }
}
```

End event:

```json
{
  "schema_version": 1,
  "event": "project_boundary",
  "ts": "2026-05-20T22:14:55Z",
  "data": {
    "slug": "nightly-refactor",
    "kind": "end",
    "workstream": "main-20260520-1730",
    "terminal_id": "term-abc",
    "status": "success",
    "note": "shipped at sha abc123"
  }
}
```

**Field presence rules** (consumers should branch on `data.kind`):

| Field         | Start                   | End                                          |
|---------------|-------------------------|----------------------------------------------|
| slug          | ✓                       | ✓                                            |
| kind          | ✓                       | ✓                                            |
| workstream    | ✓                       | ✓                                            |
| terminal_id   | ✓                       | ✓                                            |
| description   | ✓ (may be empty string) | absent                                       |
| status        | absent                  | ✓ (success / abandoned / paused)             |
| note          | absent                  | ✓ (may be empty string)                      |

The top-level `schema_version` is owned by the envelope (`.claude/hooks/lib/envelope.sh` line 6). All Pass the Baton events currently emit `schema_version=1`. Project_boundary does NOT add a per-event-type version field - bump the envelope schema_version if the contract changes.

Query via DuckDB:

```
tools/query.sh "SELECT data FROM read_json_auto('$XDG_STATE_HOME/baton/hook-events.jsonl', union_by_name=true) WHERE event='project_boundary' AND data->>'slug'='nightly-refactor'"
```

## State files

Each project gets a file at `$XDG_STATE_HOME/baton/projects/<slug>.json`:

```json
{
  "slug": "...",
  "started_at": "YYYY-MM-DDTHH:MM:SSZ",
  "ended_at": "YYYY-MM-DDTHH:MM:SSZ",
  "status": "success | abandoned | paused",
  "workstream": "...",
  "description": "...",
  "notes": ["..."]
}
```

`ended_at` and `status` are absent until `mark-end` is called. The `notes` array accumulates each note from `mark-end` calls - currently 0 or 1 entries (mark-end can only succeed once per slug), but the array shape preserves room for future patterns.

Atomic writes use `mktemp + mv` on the same filesystem.

## Privacy posture

- **Structural fields** (`slug`, `kind`, `workstream`, `terminal_id`, `status`, `started_at`, `ended_at`) - opaque identifiers + timestamps + enums. No content.
- **User-supplied free text** (`description`, `note`) - passed through verbatim from the CLI flags. Pass the Baton does not parse or transform these. **Anything you put in `--description` or `--note` reaches the event log unmodified.** Do not put secrets, prompt content, or sensitive identifiers there.
- The envelope's redactor (`envelope::_redact`) strips known-text fields (`prompt`, `completion`, `content`, `text`, `message`, `messages`, `response`) but does NOT strip `description` or `note` - they are user-controlled text channels.
