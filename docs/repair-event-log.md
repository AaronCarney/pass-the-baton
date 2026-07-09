# Repairing the hook-events log (`tools/repair-event-log.sh`, CC20)

The event log (`$XDG_STATE_HOME/baton/hook-events.jsonl`) is a best-effort
append stream. Crash / VM-pause zero-fill can leave NUL runs or blank lines (see
`lib/eventlog.sh`). Readers tolerate this on the read side, but corruption can break
downstream jq-stream consumers - most visibly, `cost.sh --arc <slug>` returning
`events: 0` for arcs whose `cost_rollup` events sit after the first corrupt line.

This tool reuses `eventlog::stream` to rewrite the log to **only** valid JSON records.
It is **backup-first**: it never truncates before a verified backup exists.

The log path auto-resolves to the same resolver the readers use - no path argument
needed. Run from the repo root (or by absolute path) so it works from any directory.

## Step 1 - Dry-run (read-only, makes no changes)

```bash
bash tools/repair-event-log.sh --dry-run
```

Prints three numbers and nothing else changes on disk:

```
dry-run: ~/.local/state/baton/hook-events.jsonl
  total lines: 234119
  kept records: 234043
  dropped: 76
```

- **`dropped` ≈ 76** (74 blank lines + 2 NUL-byte lines) → diagnosis matches, repair is safe.
- **`dropped` = 0** → log already clean, no repair needed.
- **`dropped` ≫ 76** → stop; more corruption than expected. Investigate before repairing.

The dry-run writes no backup and leaves the log byte-identical. Confirm:

```bash
ls ~/.local/state/baton/hook-events.jsonl.bak-*   # → no such file
```

## Step 2 - Real repair (only when the dry-run numbers look right)

```bash
bash tools/repair-event-log.sh
```

Copies the original aside (verifying byte size) before atomically rewriting to only
valid records. Prints the same counts plus a `backup:` line:

```
repaired: ~/.local/state/baton/hook-events.jsonl
  total lines: 234119
  kept records: 234043
  dropped: 76
  backup: ~/.local/state/baton/hook-events.jsonl.bak-<timestamp>
```

Fully reversible - the timestamped `.bak-*` holds the untouched original.

## Step 3 - Verify

After repair, `cost.sh --arc <slug>` stops returning `events: 0` for arcs after the
formerly-corrupt region. Pick a slug with `cost_rollup` events:

```bash
bash tools/cost.sh --arc cc16-livetest   # → events: 9 (was 0 pre-repair)
```

> Note: an arc legitimately reports `events: 0` if no `cost_rollup` events were ever
> stamped to that slug - that is not corruption. Use a slug you know carries cost events.
