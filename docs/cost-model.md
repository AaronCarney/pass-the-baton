# Cost Model

Single source of truth for how Pass the Baton estimates and records Claude Code session costs. Covers pricing primitives, token estimation, calibration, model pinning, freshness enforcement, the CC6 disclaimer, hook wiring, anomaly detection, flip conditions, and privacy guarantees.

---

## Five primitives

Cost is computed from five token-count fields emitted by the Claude Code API and five per-model pricing constants. All prices are USD per million tokens, verified against published Claude API pricing on 2026-06-10.

| Model | base_in | base_out | cache_write_5m | cache_write_1h | cache_read | min_cache_tokens |
|---|---|---|---|---|---|---|
| claude-opus-4-7 | 5.00 | 25.00 | 6.25 | 10.00 | 0.50 | 4096 |
| claude-opus-4-6 | 5.00 | 25.00 | 6.25 | 10.00 | 0.50 | 4096 |
| claude-sonnet-4-6 | 3.00 | 15.00 | 3.75 | 6.00 | 0.30 | 2048 |
| claude-sonnet-4-5 | 3.00 | 15.00 | 3.75 | 6.00 | 0.30 | 1024 |
| claude-haiku-4-5 | 1.00 | 5.00 | 1.25 | 2.00 | 0.10 | 4096 |

**Field semantics:**

- `base_in` - standard input tokens (not cached)
- `base_out` - output tokens
- `cache_write_5m` - cache creation tokens written with 5-minute TTL
- `cache_write_1h` - cache creation tokens written with 1-hour TTL
- `cache_read` - cache read tokens (hits on a previously written block)
- `min_cache_tokens` - minimum token count for a block to be eligible for caching (smaller blocks are billed as `base_in`)

**Turn cost formula:**

```
cost = (input_tokens        × base_in
      + output_tokens       × base_out
      + cache_creation_5m   × cache_write_5m
      + cache_creation_1h   × cache_write_1h
      + cache_read_tokens   × cache_read) / 1_000_000
```

All five fields come directly from the `usage` object in the Claude Code hook payload. No fields are synthesized.

**Implementation home:** `lib/cost-models.sh` - exports `PRICE` associative array, `cost_models::resolve_id`, and `cost_models::compute_turn_cost`.

---

## Byte-to-token estimation

When a calibrated per-session token count is unavailable (e.g., before `PostToolBatch` fires for the first turn), token counts are estimated from content-byte sizes using a per-content-type ratio table.

| Content type | bytes per token |
|---|---|
| JSON | 2.7 |
| code | 3.2 |
| diff | 3.0 |
| base64 | 2.0 |
| prose | 4.0 |

The ratio is `tokens = bytes / ratio`. Lower ratio = more tokens per byte = denser content. **These defaults are reasonable starting points anchored to commonly observed byte-pair-encoding behavior on each content type; they are not measured against any specific Anthropic tokenizer release.** For a corpus-anchored figure, run `tools/calibrate-bytes-per-token.sh --corpus <your-dir>` (see §Calibration) - it writes measured ratios to `~/.config/baton/token-ratios.sh` and the estimator picks them up automatically.

**Opus 4.7 tokenizer inflation multiplier:**

The Opus 4.7 tokenizer empirically produces more tokens than the byte-ratio model predicts. The applied defaults are a **central-tendency estimate** measured on representative content:

- `1.10×` for prose
- `1.20×` for code and structured text

The CC6 disclaimer cites an outer bound of **~1.35× for code or structured text**: pathological content (heavy unicode, dense symbols, atypical structure) can land past the default multiplier. The 15-percentage-point gap between the default (1.20) and the disclaimer cap (1.35) is deliberate - the default is calibrated for typical content; the disclaimer covers worst-case content the user might pass through. If your corpus is dense or atypical, run calibration to replace the default with a measured value.

For non-Opus-4.7 models the multiplier is `1.0×`. After running calibration (see §Calibration), the multipliers are replaced by measured values.

**Implementation home:** `lib/tokens.sh` - exports `tokens::estimate`, `tokens::estimate_file`, `tokens::load_ratios`, and `tokens::content_type_for_path`. The function `tokens::load_ratios` reads `~/.config/baton/token-ratios.sh` if present and overrides the defaults; otherwise the built-in table above applies.

---

## Calibration

Calibration measures the actual bytes-per-token ratio for a given content corpus by making a live `count_tokens` API call and comparing the result against the byte count.

**Running calibration:**

```bash
tools/calibrate-bytes-per-token.sh --corpus <directory> [--model <model-id>]
```

The script:
1. Walks `<directory>` and classifies each file by content type (JSON, code, diff, base64, prose).
2. Makes a `count_tokens` API call for each sampled file.
3. Computes `ratio = bytes / api_token_count` per content type.
4. Writes the measured ratios to `~/.config/baton/token-ratios.sh` in sourceable form.

**When to re-run:**

Re-run calibration on each Pass the Baton release that bumps the target model ID. Token ratio tables are model-specific; a new Sonnet or Opus minor version may alter tokenizer behavior.

**Consuming calibrated ratios:**

`lib/tokens.sh::tokens::load_ratios` sources `~/.config/baton/token-ratios.sh` on startup if the file exists. The file exports `BYTES_PER_TOKEN_JSON`, `BYTES_PER_TOKEN_CODE`, `BYTES_PER_TOKEN_DIFF`, `BYTES_PER_TOKEN_BASE64`, and `BYTES_PER_TOKEN_PROSE`. Any missing key falls back to the built-in default.

No calibration file → built-in defaults. Partial file → per-key fallback. The design is safe to source idempotently.

---

## Model ID pinning

**CC4 constraint (verbatim):** Pin every API call to a dated model ID (e.g., `claude-sonnet-4-6-20260101`) rather than the alias, so a silent model revision does not change the tokenizer under the user's feet without a Pass the Baton release bumping the pin.

**Current pinned IDs:**

| Alias | Pinned dated ID |
|---|---|
| claude-opus-4-7 | `claude-opus-4-7-20260101` |
| claude-opus-4-6 | `claude-opus-4-6-20260101` |
| claude-sonnet-4-6 | `claude-sonnet-4-6-20260101` |
| claude-sonnet-4-5 | `claude-sonnet-4-5-20241022` |
| claude-haiku-4-5 | `claude-haiku-4-5-20241022` |

**Alias detection and warning:**

`cost_models::resolve_id` in `lib/cost-models.sh` accepts both aliases and dated IDs. When it receives a bare alias (no date suffix), it emits a warning to stderr:

```
[cost-model] WARNING: model alias 'claude-opus-4-7' resolved to 'claude-opus-4-7-20260101'. Use the dated ID to ensure tokenizer stability.
```

The resolved dated ID is always used for pricing lookups. Callers should pass dated IDs directly; the warning exists to catch hook payloads that emit bare aliases.

**Bumping the pin at release time:**

1. Verify that the new dated ID is listed in the pricing docs and that the PRICE table still matches.
2. Update the `PINNED_IDS` map in `lib/cost-models.sh`.
3. Re-run `tools/calibrate-bytes-per-token.sh` against the new model to capture any tokenizer changes.
4. Bump `PRICING_VERIFIED_DATE` (see §Pricing freshness).
5. Commit with `chore(cost): bump pinned model IDs to <date>`.

---

## Pricing freshness

**The `PRICING_VERIFIED_DATE` constant** is defined at the top of `lib/cost-models.sh`:

```bash
PRICING_VERIFIED_DATE="2026-06-10"
```

It records the date on which the PRICE table constants were last verified against Anthropic's published pricing page.

**90-day cadence:** `tools/doctor.sh` computes `today - PRICING_VERIFIED_DATE`. If the gap exceeds **90** days, doctor emits:

```
WARNING: PRICING_VERIFIED_DATE=<date>, age=<n> days - re-verify against https://platform.claude.com/docs/en/about-claude/pricing
```

The check is non-blocking but visible on every `doctor` run after the threshold.

**Verification procedure:**

1. Open `https://platform.claude.com/docs/en/about-claude/pricing` in a browser.
2. Compare the five price columns (`base_in`, `base_out`, `cache_write_5m`, `cache_write_1h`, `cache_read`) plus `min_cache_tokens` for each model against the PRICE table in `lib/cost-models.sh`.
3. If prices are unchanged: update `PRICING_VERIFIED_DATE` to today.
4. If prices changed: update the affected PRICE constants and `PRICING_VERIFIED_DATE` to today.
5. Commit with `chore(cost): verify pricing table <YYYY-MM-DD>`.

**L1 AC#2 note:** The L1 acceptance criterion originally contained a hardcoded worked-example total (e.g., "$0.0034 per turn"). That example was patched out on 2026-05-14 in favor of this freshness mechanism. Hardcoded totals become stale when prices change; `PRICING_VERIFIED_DATE` + doctor enforcement is the durable solution.

---

## CC6 disclaimer

The following disclaimer must be surfaced wherever Pass the Baton displays cost figures to the user (CLI output, dashboard, `tools/cost.sh` summary):

> Token counts are an estimate computed from content size and Anthropic's published per-model tokenizer behavior. Actual API billing uses Anthropic's authoritative count, which may differ by up to ~5% on prose and up to ~35% on code or structured text for Opus 4.7. For a billing-grade figure, use `bash tools/cost.sh --verify --corpus DIR`.

**Implementation notes:**

- The disclaimer is emitted as a trailing footer line, not as a per-row annotation.
- Estimated and verified figures must be displayed distinctly when both are available (e.g., "Est: $0.0034 | Verified: $0.0031").
- The `--verify` flag triggers a live `count_tokens` call against the session transcript (requires `--corpus DIR`; see §Privacy).
- Short-form in log output: `[estimate, not invoice]` may substitute for the full disclaimer when space is constrained (e.g., `hook-events.jsonl` entries).

---

## PostToolBatch wiring

**Why `PostToolBatch` not `PostToolUse`:**

Claude Code may invoke multiple tools in a single turn (parallel tool calls). `PostToolUse` fires once per tool call; if five tools run in parallel, five events fire with overlapping `usage` fields - summing them double-counts. `PostToolBatch` fires once after all parallel tool calls in a turn complete, with a single consolidated `usage` object. This is the correct aggregation point for per-turn cost recording.

**Input shape** (`PostToolBatch` payload fields consumed by the cost hook):

```json
{
  "session_id": "<uuid>",
  "model": "<dated-model-id>",
  "usage": {
    "input_tokens": 1234,
    "output_tokens": 456,
    "cache_creation_input_tokens": 789,
    "cache_read_input_tokens": 101
  }
}
```

The hook reads `model` (resolved via `cost_models::resolve_id`) and all five `usage` fields. No other fields are consumed.

**`cost_rollup` event structure** (written to `hook-events.jsonl`):

```json
{
  "ts": "2026-05-14T12:34:56Z",
  "event": "cost_rollup",
  "schema_version": 1,
  "data": {
    "session_id": "<uuid>",
    "model": "claude-opus-4-7",
    "cache_read": 101,
    "cache_write_5m": 789,
    "cache_write_1h": 0,
    "fresh_input": 1234,
    "output": 456,
    "turn_index": 17,
    "threshold": 20,
    "summary_turn": false,
    "transcript_basename": "transcript.jsonl"
  }
}
```

The event carries only `usage` numerics - no per-turn USD estimate is written. Cost is computed at query time by `tools/cost.sh` against the PRICE table in `lib/cost-models.sh`, so an archived event always re-prices against the current pricing constants (and the `PRICING_VERIFIED_DATE` freshness gate above tells you when those constants were last reconciled).

**Cost reader:** `tools/cost.sh` reads `hook-events.jsonl`, filters `event == 'cost_rollup'`, and aggregates by session or model. See that file for the full query interface.

### Querying cost events with DuckDB

E7's `tools/query.sh` uses `read_json_auto` with `union_by_name=true`, which unions all event rows regardless of type. E8 introduces new event types (`cost_rollup`, `cache_anomaly`, `tools_changed`, `prewarm_ok`, `prewarm_failed`). These appear in the unioned schema automatically - no migration needed. Because different event types carry different `data` sub-fields, columns from one type read as `NULL` for rows of other types. Always scope queries with a `WHERE event=` filter to avoid noise.

**Example queries:**

1. Total tokens by model from `cost_rollup` events (USD is computed at read time by `tools/cost.sh` - see that script for the priced query):

```sql
SELECT data->>'model' AS model,
       SUM((data->>'fresh_input')::BIGINT)   AS fresh_input,
       SUM((data->>'cache_read')::BIGINT)    AS cache_read,
       SUM((data->>'cache_write_5m')::BIGINT) AS cache_write_5m,
       SUM((data->>'output')::BIGINT)        AS output
FROM read_json_auto('hook-events.jsonl', union_by_name=true)
WHERE event = 'cost_rollup'
GROUP BY model
ORDER BY output DESC;
```

2. Cache anomaly events in the last 7 days:

```sql
SELECT ts,
       data->>'session_id'      AS session_id,
       data->>'prior_creation'  AS prior_creation,
       data->>'current_creation' AS current_creation,
       data->>'ratio'           AS ratio
FROM read_json_auto('hook-events.jsonl', union_by_name=true)
WHERE event = 'cache_anomaly'
  AND ts > date_trunc('day', current_timestamp - INTERVAL 7 DAY);
```

3. Prewarm history:

```sql
SELECT ts,
       data->>'model',
       data->>'cache_creation_input_tokens'
FROM read_json_auto('hook-events.jsonl', union_by_name=true)
WHERE event = 'prewarm_ok';
```

---

## Anomaly detection

**Cache creation doubling rule:**

Each `PostToolBatch` turn, the cost hook computes the ratio:

```
ratio = cache_creation_input_tokens / prior_cache_creation_input_tokens
```

If `ratio ≥ 2.0` and `prior > 0`, a `cache_anomaly` event is emitted to `hook-events.jsonl`:

```json
{
  "ts": "2026-05-14T12:35:00Z",
  "event": "cache_anomaly",
  "schema_version": 1,
  "data": {
    "session_id": "<uuid>",
    "prior_creation": 6300,
    "current_creation": 14500,
    "ratio": 2.3
  }
}
```

A ratio ≥ 2.0 indicates that the cached prefix grew to more than double its prior size in a single turn - a common sign of a tools-array change invalidating the cache, a new system-prompt injection, or an abnormally large tool response being written into the context.

**`prior > 0` guard:** The rule only fires when a prior measurement exists. The first turn of a session (prior = 0) does not emit an anomaly regardless of how large the cache write is.

**Doctor surface:**

`tools/doctor.sh` greps the last 24 hours of `hook-events.jsonl` for `cache_anomaly` events and emits a one-line WARNING if any are found:

```
WARNING: <n> cache anomaly events in last 24h - see hook-events.jsonl
```

This gives users a lightweight signal that cache costs spiked. To inspect, query the event log directly: `bash tools/query.sh "SELECT ts, data->>'session_id', data->>'ratio' FROM read_json_auto('hook-events.jsonl', union_by_name=true) WHERE event='cache_anomaly' AND ts > now() - INTERVAL 24 HOUR"`.

---

## Flip conditions

The following conditions should trigger a re-evaluation of the model ID assumptions, pricing table, and tokenizer ratio table:

- A new Sonnet, Haiku, or Opus minor version ships. Recheck the tokenizer parity table and the per-model minimum cache token count.
- Anthropic publishes Claude Code's system+tools token count. Replace the per-session measurement with the published constant.
- Anthropic publishes a Claude 4.x local tokenizer. Switch the calibration script from network-call to local computation.
- The 1M context tier gains a long-context premium for current models. Re-introduce the threshold branch only if and when this happens in the pricing docs.
- A new pricing modifier (data residency, fast mode, geo) becomes default-on for Claude Code.

On any of these conditions: open a `chore(cost):` issue or PR that updates `lib/cost-models.sh`, re-runs calibration, and bumps `PRICING_VERIFIED_DATE`.

---

## Comparison analysis

`bash tools/cost-compare.sh` answers the headline cost question: *what does
it actually cost to use a low-vs-high checkpoint threshold, and where does the
resume pattern's cache pay off?* It is a read-only analysis layer over the cost
engine - it adds no new pricing constants.

**Two regimes:**

- *Context-grows (uncached):* no checkpoint; every turn re-sends the whole
  conversation, billed at `base_in`. Cost grows super-linearly with turns.
- *Clear+resume (cached):* at the checkpoint threshold, `/clear` is modeled as a
  total cache reset (worst case). The next turn pays one 5m cache
  write over the tools+system+resume prefix; later turns read that prefix at
  `cache_read` (0.1× input) and only bill fresh user input.

**Threshold sweep:** session cost is computed for a dense grid of thresholds -
`10, 12, 14, … 50` (every 2 percentage points) plus `never` (22 values total;
see `tools/cost-sweep-corpus.sh`) - each a context-fill % of the flat-priced 1M
window (no 200K branch). For each threshold the session **starts in the uncached regime** and
stays there until cumulative fill first reaches `T`%; at that turn the `/clear`
checkpoint fires and the session switches to the cached regime (re-clearing on
each later crossing). A **higher** threshold runs uncached longer and
checkpoints later; a **lower** threshold checkpoints sooner. `never` is the pure
uncached regime, and any threshold a short session never reaches correctly
equals `never` - that is the real economics, not a missing data point.

**Resume payoff:** uncached vs cached session total, the dollar/percent saving,
and the break-even turn (typically turn 2). Savings are suppressed
with a caveat when a "does not pay off" condition holds (single-turn
session, or prefix below the model's `min_cache_tokens`).

**Modeling simplification:** post-checkpoint turns model the entire accumulated
history as one `cache_read` against the prefix; the small per-turn incremental
cache *write* that re-anchors each completed exchange is not modeled. This makes
the cached regime modestly optimistic relative to a faithful re-derivation but
stays directionally faithful (cached ≪ uncached, break-even unchanged). The
omitted term is bounded by per-turn incremental tokens × `cache_write_5m`, and
grows with session length; for a 5-turn fixture it is a few cents at typical
prices. It is deliberate: the incremental-write arithmetic is the
internally contradictory row this analysis already rejects.

**Summary-generation cost (Addendum A).** The resume branch is not free: the
prior session spends output tokens writing the progress summary that the next
session reads. `--summary-tokens N` (env `BATON_SUMMARY_TOKENS`, default
2500; `0` disables) sets `S`. When `S` is not set explicitly, it is
auto-derived by `ccmp::derive_summary_tokens_default` through a
three-tier precedence: (1) a **live running mean** of post-`/clear`
summary-turn output
tokens kept in `lib/summary-tokens-mean.sh` (state file
`$XDG_STATE_HOME/baton/summary-tokens-mean.json`, shape `{n, mean,
skill_hash}`), updated by `post-tool-batch.sh` on every detected summary turn
and reset when the progress-file template selection changes; (2) a scan of
recent progress files; (3) the flat 2500 fallback. This running mean is the one
aggregate the telemetry layer maintains continuously on the hot path - every
other rollup is computed on demand at query time. `--summary-model ID` (env
`BATON_SUMMARY_MODEL`, default `--model`) prices the summary
independently of the session model being compared - the writer may be a
cheaper model than the session it serves. The CLI computes the per-`/clear`
USD scalar `sg = cost_of_turn(summary_model, 0, 0, 0, 0, S)` once and adds it:
(a) once at turn 1 of the cached resume-payoff total, and (b) at **every**
checkpoint firing in the threshold sweep - so thrash (low `T`) multiplies the
charge while a high `T` amortizes it across the session. `never`/uncached
never pays it. This term is modeled rather than assumed negligible because
`summary_gen / savings` is unbounded as the checkpoint nears session end and
is materially >1% for short sessions. Set `--summary-tokens 0` for
pre-2026-05 behavior.

**Cross-model summarizer input charge.** The `sg` scalar above is OUTPUT-only.
That is the correct model when `--summary-model` equals the session model: the
summarizer is the running session, the pre-`/clear` context is already in its
cache, and the marginal new spend is the generated summary's output tokens.
When `--summary-model` differs from `--model` (the explicit cross-model case
the flag was added to support), the summarizer has not seen the prior context
and must read it as fresh input at its own `base_in` rate. The CLI computes
`sg_in_rate = price(summary_model, base_in) / 1e6` (USD per input token) and
the threshold sweep charges `fill × sg_in_rate` at **every** checkpoint firing
in addition to the `sg` output scalar. Same-model summarizers use rate=0
(preserves pre-Addendum-A semantics). The JSON output surfaces this as
`summary_input_rate_usd_per_token`; the human output prints a per-`/clear`
caveat line whenever the rate is non-zero.

The resume-payoff line (`cached_usd` / `savings`) deliberately **does not**
include this cross-model input charge - it has no visibility into the prior
session's context length, so any number it picked would be a fabricated guess.
The threshold sweep does have that visibility (it tracks `fill` per turn) and
models the charge there. A cross-model run therefore shows higher threshold
totals than the same-model run while reporting an unchanged `cached_usd`; the
human output flags this explicitly with a "cached_usd excludes the cross-model
summarizer's input cost" note.

**Oracle:** all figures are first-principles `cost_models::cost_of_turn` math.
The worked-example dollar totals are *informational only* - their turn-1
"with caching" row prices a cache write at the cache-read rate (a known table
contradiction); the PRICE constants are the source of truth.

## Privacy

**CC8 enforcement:** The cost subsystem reads only `usage` numeric fields from the Claude Code transcript JSONL. It never reads, stores, logs, or transmits prompt text, completion text, tool arguments, or tool results.

**What `tools/cost.sh` reads:**

`tools/cost.sh` reads the Claude Code transcript JSONL file (e.g., `~/.claude/projects/<hash>/transcript.jsonl`) but extracts only the `usage` sub-object from each assistant message. All other fields (`content`, `tool_calls`, `tool_results`, `system`) are ignored by the jq/awk filter and never reach `hook-events.jsonl`.

**Why `--verify` requires `--corpus DIR`:**

The `bash tools/cost.sh --verify` flag performs a live `count_tokens` API call to get a billing-grade token count. To do this without reading session content, the user must supply a directory of representative files via `--corpus DIR`. The calibration script samples from that directory - it does not read the active session transcript. Reading session content for calibration would violate CC8 by sending user prompts and completions to the Anthropic API outside of the user's explicit Claude Code session.

**Audit surface:**

The full list of fields written to `hook-events.jsonl` by the cost subsystem is enumerated in §PostToolBatch wiring above. No field in any `cost_rollup` or `cache_anomaly` event contains user-generated text.

## Corpus aggregator

`tools/cost-sweep-corpus.sh` runs the threshold counterfactual model across a corpus of Claude Code transcripts and reports per-threshold summary statistics. It is the basic-rigor instrument for the question *"what checkpoint threshold % is most efficient on average for my session population?"*. The math at the corpus level is byte-identical to the single-transcript `tools/cost-compare.sh` because both source the same `ccmp::derive_prefix` and `ccmp::derive_summary_tokens_default` from `lib/cost-compare-model.sh`.

### Usage

```bash
# Default: ~/.claude/projects/, excludes subagents/ workspace, human-readable table
bash tools/cost-sweep-corpus.sh

# JSON output for downstream tooling
bash tools/cost-sweep-corpus.sh --json > /tmp/sweep.json

# Limit corpus size for fast smoke runs
bash tools/cost-sweep-corpus.sh --corpus ~/.claude/projects/ --limit 20

# Filter by workspace globs (repeatable)
bash tools/cost-sweep-corpus.sh --workspace-include 'myproject*' --workspace-exclude '*test*'

# Override model and summary model
bash tools/cost-sweep-corpus.sh --model claude-opus-4-7 --summary-model claude-haiku-4-5

# Internal identity check (must be invoked via `bash <path>`; rejects stdin redirection)
bash tools/cost-sweep-corpus.sh --self-check
```

### Output

Human-readable mode prints one row per threshold (10-50% in 2% steps + `never`, 22 rows total) with five columns: `MEDIAN`, `MEAN`, `P95`, `IQR`, `COUNT`. The final `TYPICAL-BEST` line carries two independent statistics: **median-of-best-threshold** (per-transcript best, then median) and **mode-of-best-threshold** (most-frequent per-transcript best). Agreement = strong signal; divergence = read the distribution itself.

The `--json` output schema:

```json
{
  "schema_version": 1,
  "method": "baton-threshold",
  "model": "claude-sonnet-4-6",
  "transcripts": [{"path":"...","workspace":"...","session_id":"...","best_threshold":28,"per_threshold":{"10":0.12,"12":0.11,"...":"...","never":0.45}}],
  "aggregates": {"10":{"median":0.11,"mean":0.13,"p95":0.28,"iqr":0.07,"count":460},"...":"..."},
  "typical_best": {"median": 28, "mode": 26},
  "disclaimer": "Token counts are an estimate ..."
}
```

The `method` field is fixed to `"baton-threshold"` in v1 - it is the seam for future arms (`"compact"`, `"clear-only"`, `"none"`).

### Performance

Sequential per-transcript processing. On the ~460-transcript reference corpus, expect ~3-10 minutes wall-clock on a developer laptop depending on transcript size distribution. The v1 tool does not parallelize across transcripts; per-corpus xargs/parallel is a follow-up optimization that does not affect correctness.

### Basic-rigor caveats

This tool produces **basic-rigor** evidence. It deliberately omits:

- **Confidence intervals.** No bootstrap, no standard error reporting. The `IQR` and `COUNT` columns are the only spread/sample-size signals.
- **Stratification.** All transcripts contribute equally regardless of workspace, session length, model, or session date. Per-workspace or per-session-shape conditional answers require post-processing the JSON output.
- **Cross-method comparison.** No comparison against Anthropic `/compact`, auto-memory, `/clear`-only, or do-nothing. The instrument compares thresholds *within Pass the Baton*, not techniques.
- **Project-boundary aggregation.** Per-transcript only. There is no "per completed project" or "per body of work" rollup; each transcript counts once.

Extreme-rigor scope (confidence intervals, stratification, cross-method comparison, project-boundary work) is planned follow-up work.

### Privacy

Identical CC8 posture to the rest of the cost stack. Reads only `usage` numerics from transcripts. No prompt or completion text touches the output. No network paths.
