# Telemetry

Pass the Baton writes one JSON line per hook event to a local append-only log. Local-only by construction - there is no network code path, no remote sink, no opt-in upload. The log exists so you can answer questions like "how often did the checkpoint trigger fire today?" or "what's the summarizer-window wall-clock distribution across my last N sessions?" without instrumenting anything yourself.

**Opt out:** export `BATON_EVENT_LOG_DISABLE=1`. The hooks become no-ops on the write path; everything else (state transitions, session injection, cron sweep) continues to work. No file is created.

**Default location:** `$XDG_STATE_HOME/baton/hook-events.jsonl` (typically `~/.local/state/baton/hook-events.jsonl`). Override with `BATON_EVENT_LOG=/some/other/path`.

> **Two files share this basename.** This document covers only the structured telemetry log above, written by `envelope::emit` in `.claude/hooks/lib/envelope.sh`. A second, unrelated file at `$BATON_DIR/hook-events.jsonl` (typically `<repo>/.baton/hook-events.jsonl`, gitignored) is written by `log_event` in `.claude/hooks/lib/workstream-lib.sh` for project-local forensic audit (workstream selection outcomes, basename-rejects, sticky writes). It has a different shape, is not covered by `BATON_EVENT_LOG_DISABLE`, and is documented in [`docs/context-baton.md`](context-baton.md) (see the [Files](context-baton.md#files) table row and the Troubleshooting `jq` examples for `basename-reject`).

**File mode:** 0600 on creation. Never `/tmp`, never world-readable.

This document is the single source of truth for the envelope, field names, redaction posture, and the conditions under which we would replace this design with something else. **The intent is that this doc and `.claude/hooks/lib/envelope.sh` + the per-hook emit sites stay in lock-step; if you read a field name here, you can grep it in the hooks and find the emit.**

---

## Envelope

Every line is a complete JSON value. No multi-line records, no leading/trailing whitespace, one event per line. Frozen shape:

```json
{"schema_version":1,"event":"PreToolUse","ts":"2026-05-16T23:54:07Z","data":{"tool_name":"Read","context_pct":18,"threshold":20,"pending_set":false}}
```

Fields:

- `schema_version` - integer. Currently `1`. Increments on renames or removals. Additive changes do not bump.
- `event` - string. See [Field reference](#field-reference) for the full set.
- `ts` - ISO-8601 UTC timestamp, **second resolution**, `Z` suffix. The writer uses `date -u +%Y-%m-%dT%H:%M:%SZ`. Sub-second event ordering is preserved by append order, not by timestamp comparison.
- `data` - object. Event-specific keys; see below.

**Size cap:** records ≤ 512 B take a lock-free append; records 513 - 4096 B take a `flock`-guarded append; records that would exceed 4096 B are replaced with a stub `{schema_version, event, ts, truncated:true, original_bytes:N}` and dropped. The 4096 B ceiling is enforced at write time by `envelope::emit`; no current emit site produces records that approach it.

---

## Field reference

All `data.*` keys are optional from a parser's standpoint - consumers must ignore unknown keys and tolerate missing ones. The keys below are the documented set per event as of `schema_version=1`. **Every key listed is grep-able in `.claude/hooks/`; nothing here is aspirational.**

### `PreToolUse` - every tool call

Emitted by `.claude/hooks/context-checkpoint.sh` on every PreToolUse hook fire.

| Key | Type | Meaning |
|---|---|---|
| `tool_name` | string | Tool that is about to fire (`Bash`, `Edit`, `Write`, …). |
| `context_pct` | integer | Approximate context-fill percentage from the statusline at trigger time. `0` if the statusline file is missing. |
| `threshold` | integer | The configured checkpoint threshold (default `20`). |
| `pending_set` | boolean | `true` if this PreToolUse just set the deferred-save flag (i.e., the checkpoint was triggered on this call). At most one `pending_set=true` event per session per checkpoint cycle. |

### `PostToolUse` - checkpoint cleanup only

Emitted by `.claude/hooks/checkpoint-write-trigger.sh` **only when a `progress-*.md` write fires the cleanup path** - not on every tool call. The `duration_ms` field measures the cleanup hook's own wall-clock (pointer rewrite + archive moves), not the underlying tool call.

| Key | Type | Meaning |
|---|---|---|
| `tool_name` | string | The matched write tool (`Write`, `Edit`, or `MultiEdit`). |
| `workstream` | string | Bound workstream slug, or `""` if unbound. |
| `terminal_hash` | string | Short terminal hash (`<6+ hex>`). |
| `progress_file_basename` | string | Basename of the written progress file (cross-workstream guard input). |
| `duration_ms` | integer | Wall-clock milliseconds for the cleanup hook itself. |

### `SessionStart`

Emitted by `.claude/hooks/session-start.sh` on every session start, after the workstream-binding resolver runs.

| Key | Type | Meaning |
|---|---|---|
| `matcher` | string | The SDK-supplied source value (`startup`, `resume`, `clear`, `compact`). |
| `workstream` | string | Workstream slug after routing, or `""` if no binding could be resolved. |
| `terminal_hash` | string | Short terminal hash. |
| `binding_found` | boolean | `true` if the workstream binding was resolved (either pre-created via AGENT_SESSION_ID Case A, parent-state Case B, or fresh-create from terminal hash). |

### `UserPromptSubmit`

Emitted by `.claude/hooks/project-detect.sh` on every user prompt.

| Key | Type | Meaning |
|---|---|---|
| `project_slug` | string | The project name matched (via `projects/<name>` symlink or `rename this session to X` pattern), or `""` if no match. |
| `prompt_bytes` | integer | Length in bytes of the submitted prompt. The text itself is never captured. |

### `tool_call` - opt-in per-tool latency

Emitted by `.claude/hooks/tool-timing.sh` (PostToolUse, matcher `""` = all tools) **only when `BATON_TIMING=1`**. Off by default. When unset or `0`, the hook drains stdin and exits without emission (sub-millisecond off-path cost).

The `duration_ms` is the SDK-provided tool wall-clock (per Claude Code's PostToolUse hook input contract - excludes permission prompts and PreToolUse hooks). The `hook_overhead_ms` is this hook's own emission cost; analysis tools should report it alongside the latency quantiles so the user can see the instrumentation tax they are paying.

| Key | Type | Meaning |
|---|---|---|
| `tool_name` | string | Tool that just completed. |
| `duration_ms` | integer | SDK-provided tool wall-clock. |
| `hook_overhead_ms` | integer | This hook's own wall-clock through emit-prep (excluding the final append). Lower bound on instrumentation cost. |
| `workstream` | string | Bound workstream slug, or `""` if unbound. |
| `terminal_hash` | string | Short terminal hash. |
| `tool_use_id` | string | SDK-provided unique tool-call identifier. |

### `cost_rollup` - per PostToolBatch

Emitted by `.claude/hooks/post-tool-batch.sh` on every PostToolBatch hook fire, after reading the last assistant `.message.usage` block from the transcript.

| Key | Type | Meaning |
|---|---|---|
| `session_id` | string | SDK session ID. |
| `model` | string | Model used for the last assistant message (e.g., `claude-opus-4-7`). |
| `cache_read` | integer | `cache_read_input_tokens`. |
| `cache_write_5m` | integer | 5-minute-TTL ephemeral cache writes. Falls back to flat `cache_creation_input_tokens` when the detailed split is absent. |
| `cache_write_1h` | integer | 1-hour-TTL ephemeral cache writes. `0` when the detailed split is absent. |
| `fresh_input` | integer | Uncached input tokens. |
| `output` | integer | Output tokens. |
| `turn_index` | integer | Count of assistant messages observed in the trailing 50 transcript lines. |
| `threshold` | integer | The checkpoint threshold in effect for this turn, via `checkpoint_threshold` (env > config > default 20). Lets cost be correlated to the threshold setting. |
| `summary_turn` | boolean | `true` on the first turn after a `/clear` (detected by `turn_index` dropping). Marks the re-prime turn; its output tokens feed the summary-tokens running mean (see [cost-model](cost-model.md)). |
| `transcript_basename` | string | Basename of the transcript file. |

### `cache_anomaly`

Emitted by `.claude/hooks/post-tool-batch.sh` when the current turn's cache_creation total ≥ 2× the prior turn's value for the same session.

| Key | Type | Meaning |
|---|---|---|
| `session_id` | string | SDK session ID. |
| `prior_creation` | integer | Previous turn's cache_creation total. |
| `current_creation` | integer | This turn's cache_creation total. |
| `ratio` | number | `current / prior`. |

### `tools_changed`

Emitted by `.claude/hooks/context-checkpoint.sh` when the canonical-JSON SHA-256 of `tool_input.tools` differs from the prior fire. Production PreToolUse payloads do not include a tools array, so this event is essentially test-only in practice; emit logic remains for future SDK changes.

| Key | Type | Meaning |
|---|---|---|
| `prior_hash` | string | Previous SHA-256 hex. |
| `current_hash` | string | Current SHA-256 hex. |
| `session_id` | string | SDK session ID. |

### `prewarm_ok` / `prewarm_failed`

Emitted by `.claude/hooks/session-start.sh`'s pre-warm path when `BATON_PREWARM=1` and gates pass.

`prewarm_ok`: `{model, cache_creation_input_tokens}`. `prewarm_failed`: `{status_code, error}`.

### `tuner_snapshot` - per main session (collection-gated)

Emitted by `.claude/hooks/session-start.sh` once per **main** session, from inside the collection-gated controller block (after `threshold_controller::run_once`), via `threshold_controller::emit_snapshot`. Records the **resolved** threshold-tuner knob vector so a session's knob setting can be joined to its `cost_rollup` by `session_id` (`cost_rollup` always carries it - `post-tool-batch.sh:118`). `outcome_proxy` rows do **not** reliably carry `session_id`: `outcome_proxies::emit_event` merges only `subkind`+`threshold` (`.claude/hooks/lib/outcome-proxies.sh:43-48`), so `follow_up`/`commit_survival` are slug/workstream aggregates with no `session_id`, and `retry`/`code_execution` include it only when the originating hook had one. Join the tuner knobs to `outcome_proxy` via the slug/workstream rollup, not directly by `session_id`. The call sits inside the collection gate (an open arc or `BATON_COLLECT=1`), so a non-collecting session never emits it (and `envelope::emit` additionally self-gates on collection); subagent (Case B) sessions exit before the block. `threshold` is read **after** any `run_once` apply, so it reflects the session's effective value (including a `BATON_PCT_THRESHOLD` pin).

| Key | Type | Meaning |
|---|---|---|
| `session_id` | string | SDK session ID. Direct join key to `cost_rollup`. `outcome_proxy` rows are slug/workstream-scoped (no reliable `session_id`), so join those via the rollup, not directly. |
| `threshold` | integer | Effective checkpoint threshold (pct) after this session's tick, via `checkpoint_threshold`. |
| `setpoint` | string | Resolved `tune_setpoint` - target score (score-space, may be fractional). |
| `deadband` | string | Resolved `tune_deadband` - tolerance band around the setpoint (score-space). |
| `step` | integer | Resolved `tune_step` - threshold step size in pct points. |
| `safety_min` | integer | Resolved `tune_safety_min` - lower threshold safety bound. |
| `safety_max` | integer | Resolved `tune_safety_max` - upper threshold safety bound. |
| `dwell_seconds` | integer | Resolved `tune_dwell_seconds` - minimum seconds between applies. |
| `score_fn` | string | Resolved `tune_score_fn` - selected scoring function (default `score_hold`, a no-op). |
| `collect` | integer | Resolved `BATON_COLLECT` (0/1) at emit time. |

The recorded values are the tuner's *placeholder* defaults until the owner sets real numbers; this event is what makes the placeholder-to-tuned transition observable per session.

### `threshold_applied` - adaptive-tuner apply (collection-gated)

Emitted by `lib/threshold-controller.sh::_emit_applied` **only** when the tuner
actually writes a new threshold - i.e. the decision was not HOLD and every guard
(env-pin, safety band, dwell) passed. Under the shipped placeholder
`score_fn=score_hold` the tuner always decides HOLD, so this event is **not
emitted in practice today**; it becomes live once a real scoring function is
configured. No consumer reads it yet.

| Key | Type | Meaning |
|---|---|---|
| `old_threshold` | integer | Threshold before the apply. |
| `new_threshold` | integer | Threshold after the apply. |
| `action` | string | `up` or `down` (never `hold` - a hold emits nothing). |
| `score` | string | The score that drove the decision (score-space; may be fractional). |

### What is not captured today

Two categories of data that this telemetry layer **does not** record by default, and that any analysis claim against the on-disk events must therefore avoid asserting unless the corresponding capture is enabled:

1. **Per-tool wall-clock (opt-in).** `tool_call` events are emitted only when `BATON_TIMING=1`. With the gate off, the on-disk stream contains no per-tool latency data - only the checkpoint-write cleanup hook's self-timing under the `PostToolUse` event. Set the env var in your shell rc to make `tools/latency.sh` populate. See `tool_call` above and [Design weaknesses](#design-weaknesses) #8.
2. **Tool argument hashes / counts / bytes.** `envelope::_redact` contains a `summarize_args` jq path that converts a `tool_input` / `args` / `arguments` object to `{arg_count, total_bytes, sha256, first64}`, but no current emit site puts those keys in its data payload, so the summarizer is defensive code that never runs. If a future hook starts emitting tool input, the summarizer will redact it before write.

**Tool exit code / success.** Not captured today. The SDK passes `tool_response` to PostToolUse, and the shape varies per tool (`{success:true}` for write tools, `{exit_code:0,stdout:"..."}` for Bash, etc.). The `tool_timing` hook deliberately does not extract these because a uniform schema across all tools would require a per-tool extractor and the analyst use cases for it have not been articulated. If/when needed, the field is additive under the existing schema version.

---

## OpenTelemetry mapping

We bind *semantics* to OTel's `gen_ai.*` conventions, not field *names*. The on-disk JSONL uses our internal names; export-time translation lives in `.claude/hooks/lib/otel_mapping.sh` and is applied per-line when piped through `otel::rename_line`. This is deliberate - the `gen_ai.*` convention is formally Status: Development and renames fields between minor releases. Binding directly would break the on-disk format every six weeks.

Current mapping (tracking semantic-conventions v1.40.0, 2026-02-19):

| Internal `data.*` key | `gen_ai.*` name | Emitted today by |
|---|---|---|
| `model` | `gen_ai.request.model` | `cost_rollup`, `prewarm_ok` |
| `session_id` | `gen_ai.conversation.id` | `cost_rollup`, `cache_anomaly`, `tools_changed` |
| `tool_name` | `gen_ai.tool.name` | `PreToolUse`, `PostToolUse` |
| `provider` | `gen_ai.provider.name` | *(none - forward-compat row)* |
| `tokens_in` | `gen_ai.usage.input_tokens` | *(none - `cost_rollup` uses split-by-tier names like `fresh_input` / `cache_read` instead)* |
| `tokens_out` | `gen_ai.usage.output_tokens` | *(none - `cost_rollup` emits `output` directly)* |

The mapping function passes unknown `data.*` keys through unchanged (additive). When OTel renames again, one file changes. The JSONL on disk is untouched.

The forward-compat rows are kept so that if a future hook starts emitting `provider` / `tokens_in` / `tokens_out`, the rename is already in place.

---

## Redaction policy

Enforced at envelope-build time by `envelope::_redact`, in the same code path as the size cap, so the two invariants cannot drift. Concrete behavior:

- **Prompt and completion text is never captured.** `envelope::_redact` strips any `prompt`, `completion`, `content`, `text`, `message`, `messages`, `response` key from `data` before write, at any depth. `UserPromptSubmit` records the *fact* of submission and the prompt length in bytes - no content.
- **Tool input is summarized, not captured, when present.** Any `args`, `arguments`, or `tool_input` key under `data` is replaced with `{arg_count, total_bytes, sha256, first64}` - first 64 chars are kept for grep-ability, full payload is replaced with its base64 of the literal string. *No current emit site includes these keys; the summarizer is a defensive guard for future hooks.*
- **Paths are recorded as basenames.** Any string `data.*` value beginning with `/` is rewritten to its basename. Avoids leaking usernames, project names, or directory structure if the log is later shared.
- **No environment variable values, no secrets, no auth tokens.** The writer has no path that emits these.
- **File mode 0600 on creation.** Enforced by the writer's first append (`umask 0177`), then re-chmodded each write as defense in depth.
- **Default location is `$XDG_STATE_HOME/baton/`**, not `/tmp` and not a world-readable directory.

The privacy posture is structural, not policy. There is no network code path in the tool. If a remote sink is ever proposed, it requires an explicit env var and a one-time consent prompt - and it would be a flip-condition event (see below).

---

## File layout

```
$XDG_STATE_HOME/baton/
├── terminals/<hash>.json              # two-file state, existing
├── workstreams/<ws>.json              # two-file state, existing
├── hook-events.jsonl                  # active event log, mode 0600
├── hook-events.jsonl.20260512.zst     # rotated, zstd -19
├── hook-events.jsonl.20260511.zst
└── ...
```

The two-file state (`terminals/`, `workstreams/`) is unchanged from the pre-telemetry design and documented in [`docs/context-baton.md`](context-baton.md). The event log lives alongside it.

---

## Rotation

Daily, 30-day retention, zstd-compressed. Driven by `logrotate(8)` 3.18.0 or newer (which added native zstd via `compresscmd`).

Snippet shipped at `share/logrotate.d/baton`:

```
~/.local/state/baton/hook-events.jsonl {
    daily
    rotate 30
    missingok
    notifempty
    compress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions "-19 -T0 --rm"
    delaycompress
    copytruncate
    su "$USER" "$USER"
}
```

- `copytruncate` is chosen over `create` because each hook opens, appends, and closes per event. `copytruncate` is the correct pattern for that and avoids writers continuing to write to an unlinked inode.
- `delaycompress` ensures the just-rotated file is quiescent for one cycle before compression - a slow writer cannot race compression.
- `-19 -T0 --rm` yields ~5-7× ratios on JSONL hook payloads, parallel across cores, and removes the uncompressed file after compression.

The install step (`tools/install.sh`) copies this file into `/etc/logrotate.d/` (system) or wires a user-cron `logrotate --state ~/.local/state/baton/logrotate.state` invocation on systems where root install is not available.

---

## Querying

Two paths. Both read the live `hook-events.jsonl` plus rotated `.jsonl.zst` shards in the same directory.

### `bash tools/query.sh "<sql>"`

Wraps DuckDB. DuckDB reads `.jsonl.zst` natively. The wrapper does `SELECT * FROM read_json_auto([...], format='newline_delimited', union_by_name=true)` so every column from every event type is unioned - missing columns return NULL per row, which is what you want for cross-event queries.

Example: count events by type today.

```bash
bash tools/query.sh "
  SELECT event, COUNT(*) AS n
  FROM events
  WHERE ts::TIMESTAMP > now() - INTERVAL 1 DAY
  GROUP BY event
  ORDER BY n DESC;
"
```

Example: how often the checkpoint trigger fired this month.

```bash
bash tools/query.sh "
  SELECT date_trunc('day', ts::TIMESTAMP) AS day, COUNT(*) AS triggers
  FROM events
  WHERE event = 'PreToolUse'
    AND data->>'pending_set' = 'true'
  GROUP BY day
  ORDER BY day;
"
```

Example: summarizer-window wall-clock (approximate, second resolution) - pair each `pending_set=true` PreToolUse with the next `PostToolUse` carrying a `progress_file_basename`, take the `ts` delta. Note that the pairing is chronological-next, not session-id-keyed (PreToolUse does not carry `session_id`), so concurrent sessions can interleave; for low-volume checkpoint usage this is "good enough."

```bash
bash tools/query.sh "
  WITH pre AS (
    SELECT ts::TIMESTAMP AS pre_ts
    FROM events
    WHERE event = 'PreToolUse' AND data->>'pending_set' = 'true'
  ),
  post AS (
    SELECT ts::TIMESTAMP AS post_ts, data->>'workstream' AS ws
    FROM events
    WHERE event = 'PostToolUse' AND data->>'progress_file_basename' IS NOT NULL
  )
  SELECT pre.pre_ts, post.post_ts,
         date_diff('second', pre.pre_ts, post.post_ts) AS summarizer_secs,
         post.ws
  FROM pre ASOF JOIN post ON post.post_ts >= pre.pre_ts
  ORDER BY pre.pre_ts;
"
```

If `duckdb` is not on `$PATH` the subcommand exits non-zero with an actionable error pointing at install docs. We pin no DuckDB version; it is a soft optional dependency.

### `jq` fallback

For filter-and-count work, `jq` over the live log is fine up to ~100 MB. Example: event-type counts.

```bash
jq -r '.event' ~/.local/state/baton/hook-events.jsonl \
  | sort | uniq -c | sort -rn
```

Example: checkpoint trigger count.

```bash
jq -r 'select(.event == "PreToolUse" and .data.pending_set == true) | .ts' \
   ~/.local/state/baton/hook-events.jsonl \
  | wc -l
```

To include rotated shards:

```bash
zstdcat ~/.local/state/baton/hook-events.jsonl.*.zst \
        ~/.local/state/baton/hook-events.jsonl \
  | jq -r '.event' | sort | uniq -c | sort -rn
```

Aggregations (quantiles, group-by-time-bucket) are doable in `jq` but painful past 10-100 MB; that's the line at which DuckDB starts paying for itself.

---

## NFS / networked filesystems

`flock(2)` advisory semantics vary by NFS client/server combo and NFS version. `fsync` durability is also weaker - NFS clients can ack before server-side flush. Three reputable sources warn against placing append-only audit-style logs on NFS: Richard Guy Briggs (upstream auditd maintainer) on linux-audit, SUSE Knowledge Base 000021145, and the Red Hat RHEL 7 Security Guide.

The `auditd.conf(5)` man page does not categorically forbid it. Neither do we.

**Installer behavior.** On install (and on `bash tools/doctor.sh`), we detect when `$XDG_STATE_HOME` resolves onto a filesystem whose type matches `nfs`, `nfs4`, `cifs`, or `smbfs` - via `stat -f -c %T` on Linux, `df -T` fallback, `mount` parsing on macOS - and **warn**, with a pointer to this section. We do not refuse to run. Users on networked home directories (university lab machines, AD-joined corporate laptops) are a real population, and a hard refusal would push them to disable telemetry entirely.

**Workaround:** set `BATON_EVENT_LOG=/local/path/hook-events.jsonl` to redirect the log onto a local filesystem (e.g., `/var/tmp/$USER/baton/` or `~/Library/Caches/baton/` on macOS). State files (`terminals/`, `workstreams/`) can remain on the NFS-backed home if cross-machine sync is desired - they use atomic rename, not `flock`, on the hot path.

---

## Flip conditions

We will revisit this entire design if any of the following becomes true:

1. **Median session log size exceeds 100 MB.** At that scale `jq`-on-uncompressed becomes painful enough that the "human-readable mid-incident" property erodes, and a binary indexed format becomes worth its complexity.
2. **A second concurrent writer process is added** (e.g., a sidecar uploader). The lock-free ≤512 B path assumes one logical writer per file; multiple writers force `flock` on every record and the size cap stops paying for itself.
3. **Remote aggregation is required.** A network sink invalidates the local-only privacy posture and reopens the Vector / Fluent Bit decision.
4. **OpenTelemetry `gen_ai.*` reaches Stable status** and renames stop. At that point the indirection in `lib/otel_mapping.sh` can be removed and field names aligned directly.
5. **A non-bash hook runtime ships in Claude Code.** If hooks gain a native runtime with structured emit, the "must be appendable from `echo`" constraint disappears and SQLite or a daemon becomes viable.

---

## Design weaknesses

Honest accounting of where this design is fragile or makes bets the maintainer should know about:

1. **The 512-byte cap is a real constraint on what we can log.** Anything richer than counts, hashes, and short identifiers gets truncated. A future "log the diff that PostToolUse produced" feature does not fit and would force the `flock` path universally.
2. **`flock` on macOS over networked home directories is not reliable.** The NFS warning is a partial mitigation, not a fix. A user with a CIFS-backed home who ignores the warning can produce interleaved records.
3. **Skip-and-warn on torn final line is a tradeoff against detection of writer bugs.** A genuinely buggy writer that emits truncated lines mid-file will be caught; one that only ever truncates the final line will not.
4. **Schema versioning is a discipline, not a mechanism.** Nothing in the writer prevents a careless contributor from renaming a field without bumping `schema_version`. The test suite covers documented invariants but cannot catch a semantic rename that preserves field presence.
5. **DuckDB as an optional dependency is a soft commitment.** If DuckDB makes a breaking change to `read_json_auto` or to zstd handling, the query subcommand breaks for users who upgrade. We pin no version; we cannot, in a bash tool.
6. **`copytruncate` has a small race window** between the copy and the truncate during which a write can be lost. logrotate documents this; we accept it because the alternative (`create` with writer reopen) requires SIGHUP-style coordination that bash hooks cannot reasonably provide.
7. **The OTel mapping table will drift.** "One file" is the smallest possible drift surface, but as long as `gen_ai.*` is in Development status, exports from an older Pass the Baton will use names the OTel ecosystem has already moved on from.
8. **Per-tool latency is opt-in.** `tool_call` events are emitted by `tool-timing.sh` only when `BATON_TIMING=1`. With the gate off (the default), per-tool quantiles and "p95 Bash latency" are not derivable from the on-disk stream - only the checkpoint-write cleanup hook's self-timing appears under `PostToolUse`. The opt-in posture is deliberate: the SDK fires PostToolUse for every tool call, so an always-on emitter would write one envelope per tool call, growing the log roughly proportional to session length. With `BATON_TIMING=1`, each event includes `hook_overhead_ms` so the user can see the instrumentation tax they are paying without a separate calibration step.
9. **`ts` resolution is one second.** Sub-second event ordering is preserved by file append order but is not in the timestamp. Sub-second `duration_ms` measurements are derivable only via in-hook timing (as `checkpoint-write-trigger.sh` does today), not via `ts` arithmetic across events. Upgrading the writer to `date -u +%Y-%m-%dT%H:%M:%S.%3NZ` is non-breaking under additive-evolution rules; it has not been done because no current consumer needs millisecond precision.

---

## Schema evolution

`schema_version` is an integer. Currently `1`. Rules:

1. **Additive within a version.** New fields under `data` may be added without bumping `schema_version`. Consumers must ignore unknown fields. This is the common case and accounts for nearly every change.
2. **Renames bump `schema_version` and require dual-write.** The writer emits *both* the old and new names for one full release cycle before the old one is dropped. A downgraded reader can still parse during the transition window.
3. **No in-place removal.** Removed fields become `null` or are omitted, but a removed name is never re-purposed for a different meaning.
4. **New event types are additive.** A new `event` value can be added without bumping `schema_version`. Consumers must tolerate unknown event names.

**CHANGELOG hooks.** Every change to the event payload that bumps `schema_version` is called out in `CHANGELOG.md` under a `### Telemetry` subheading, with the old name, the new name, the release in which dual-write begins, and the release in which the old name is dropped. Additive changes are noted but do not require a dedicated subheading.

The discipline is the mechanism. There is no schema-registry process, no runtime validation against a JSON Schema document. Reviews and the test suite carry the load.
