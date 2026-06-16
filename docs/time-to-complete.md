# Time-to-Complete Corpus Tool

**Headline norm:** This tool's defensible output is the `paired_delta` block; unpaired per-method aggregates are descriptive context only - see §8 for caveats.

## 1. Overview

`tools/time-to-complete-corpus.sh` measures per-project wall-clock duration from `project_boundary` events in a JSONL event log. It aggregates durations per method via **per-session attribution**, with subset stratification, and optionally emits a paired-difference block comparing the same project slug across methods.

The tool sources helpers from `lib/time-to-complete.sh`. The CLI handles flags, filtering, session annotation, and JSON emission; the library provides the pure computation functions (`time_to_complete::compute_per_project`, `time_to_complete::find_sessions`, `time_to_complete::infer_method`, `time_to_complete::aggregate_per_method`, `time_to_complete::paired_delta`).

Typical invocation:

```bash
tools/time-to-complete-corpus.sh \
  --events ~/.local/state/baton/hook-events.jsonl \
  --corpus ~/.claude/projects \
  --paired
```

## 2. Inputs and Wall-clock computation

`wall_clock_seconds = floor(end_ts - start_ts)` per `project_boundary` pair, where the pair is `{kind=start, kind=end}` with matching `(slug, workstream)`, keyed at first-end-after-start (sorted by `ts` ascending). Unpaired starts are silently dropped - only closed projects count.

The pairing logic is implemented in `time_to_complete::compute_per_project` (lib). It emits one JSON line per closed project.

## 3. Method inference (per session)

Per-session method label is derived from that single session's `subset_stratify` signals:

- `compact` if `subset_stratify::compaction_fired == 1` on that session
- `clear-only` if no compact-fired but `subset_stratify::clear_used == 1` on that session
- `none` otherwise (session is readable but neither flag fired)

Each project's wall-clock is attributed once per session that overlaps its `[start_ts, end_ts]` window. Multi-subset projects therefore appear in multiple method buckets (one row per session). Session-to-project association is **temporal**: the wrapper globs `*.jsonl` recursively (depth ≤ 2) under the corpus root and keeps sessions whose first-event ts falls inside the project window. The corpus layout is Claude's standard `~/.claude/projects/<workspace-mangled-path>/<uuid>.jsonl` (where `<workspace-mangled-path>` = the absolute cwd with `/` replaced by `-`), but the resolver does NOT filter by directory name - only by ts overlap.

**Auto-memory is not inferable from session subset signals in v1.** Use `--method-map <json>` to tag specific slugs as `auto-memory` (or any other override). The map is consulted first; inference is the fallback. **Auto-memory bias caveat: without `--method-map`, the `none` bucket conflates true no-management with auto-memory; treat unpaired `none`-vs-others contrasts as untrustworthy.**

**No-session-overlap caveat:** projects whose start/end window contains no overlapping transcripts get a synthetic record tagged `method_inferred="none"` (or the `--method-map` override). These contribute to the `none` bucket alongside true no-management projects, inflating its count beyond what the inference signals would warrant. As with the auto-memory bias, treat unpaired `none`-vs-others contrasts as untrustworthy when corpus coverage may be incomplete.

## 4. Filter flags and semantics

- `--method <enum>` - restrict to one method bucket. Values: `none|auto-memory|clear-only|compact` (validated at startup; invalid value → rc=1).
- `--status <s>` - restrict to project_boundary `status` value (e.g. `shipped`, `abandoned`).
- `--workspace <glob>`, `--workspace-exclude <glob>` - glob filter on workstream id. Repeatable.
- `--date-from <ISO>`, `--date-to <ISO>` - filter on project `start_ts`. UTC ISO-8601 boundaries (inclusive on both ends; string comparison since ISO-8601 sorts correctly).

**Auto-memory bias caveat (repeated for visibility): without `--method-map`, the `none` bucket conflates true no-management with auto-memory; treat unpaired `none`-vs-others contrasts as untrustworthy.**

## 5. Subsets and subset awareness (per-session attribution)

Each session carries its own subset flag: `fired` if `compaction_fired == 1` on that session, else `clean`. The aggregator preserves this granularity - per-method aggregates surface a `by_subset.{clean|fired}` sub-block whenever both subsets are present in a method's session set. `--subset <clean|fired|both>` (default `both`) filters which sessions enter the aggregate. Multi-subset projects therefore contribute distinct rows to both buckets, never collapsing to a single project-level subset label.

## 6. Paired-difference reporting

`--paired` adds a `paired_delta` block listing every slug that appears under ≥2 distinct `method_inferred` values. Per `(slug, method)`, multi-run records are reduced to a single representative by **mean** `wall_clock_seconds` before pair generation; `method_a != method_b` is enforced (no same-method duplicates). For each paired slug, the block emits all pairwise `{method_a, method_b, delta_seconds, ratio}` tuples (sorted by method name for determinism). `delta_seconds = secs[method_a] - secs[method_b]`; `ratio = secs[method_a] / secs[method_b]` (null when divisor is zero). **Recommended usage is paired-only:** unpaired per-method aggregates over different project populations are confounded by user idle time and cross-user variance (see §8).

**Subset confound in paired comparisons:** v1 `paired_delta` is subset-agnostic - when a slug ran under different subsets across methods, the reported delta is confounded by the subset effect. For subset-controlled paired output, restrict the input with `--subset fired` or `--subset clean` before invoking `--paired`. (The CLI already supports this composition; only the doc previously omitted the workaround.)

## 7. JSON Output schema

```jsonc
{
  "schema_version": 1,
  "tool": "time-to-complete-corpus",
  "filters": {
    "method": null,        // or one of: none|auto-memory|clear-only|compact
    "status": null,        // or arbitrary string from project_boundary status
    "workspace": null,     // comma-joined list of include globs
    "subset": "both",      // or clean|fired
    "date_from": null,     // ISO-8601 UTC or null
    "date_to": null
  },
  "per_method": {
    "compact": {
      "n": 3,
      "mean_seconds": 5400,
      "median_seconds": 5100,
      "p25_seconds": 4200,
      "p75_seconds": 6300,
      "projects": ["proj-a", "proj-b", "proj-c"],
      "by_subset": {
        "fired": {"n": 2, "mean_seconds": 5000, "median_seconds": 5000, "p25_seconds": 4200, "p75_seconds": 5800, "projects": ["proj-a","proj-b"]},
        "clean": {"n": 1, "mean_seconds": 6300, "median_seconds": 6300, "p25_seconds": 6300, "p75_seconds": 6300, "projects": ["proj-c"]}
      }
    }
    // ...other methods present in the filtered corpus
  },
  "paired_delta": [    // present iff --paired was supplied; an empty [] means no slug spanned ≥2 methods (distinct from key absence).
    {
      "slug": "demo",
      "pairs": [
        {"method_a": "compact", "method_b": "none", "delta_seconds": -3600, "ratio": 0.5}
      ]
    }
  ]
}
```

**v2 forward-compat note:** v2 will add `per_method.<method>.by_subset.{clean|fired}` as additive children when subset-aware breakdown lands more deeply (already present in v1 as a forward-compat seed). v1 readers reading `per_method.<method>.n` will be unaffected. New keys may be added at the top level without bumping `schema_version`; consumers should ignore unknown keys.

## 8. Confounding caveats

The metric is wall-clock - it includes user idle time (the time the user spent reading, away from the terminal, asleep, etc.) between assistant turns. Cross-user comparisons are not defensible because users differ in attention pattern, typing speed, and tolerance for parallel-tab work. The unpaired per-method aggregate is therefore a noisy / biased estimate of "how long a project takes under method X"; treat the aggregate as descriptive context, not a causal claim. The **paired-difference block** is the defensible surface - when the *same* slug ran under two methods on the same user, the delta isolates the method effect.

**Auto-memory bias caveat: without `--method-map`, the `none` bucket conflates true no-management with auto-memory; treat unpaired `none`-vs-others contrasts as untrustworthy.**

**No-session-overlap caveat:** projects whose start/end window contains no overlapping transcripts get a synthetic record tagged `method_inferred="none"` (or the `--method-map` override). These contribute to the `none` bucket alongside true no-management projects, inflating its count beyond what the inference signals would warrant. As with the auto-memory bias, treat unpaired `none`-vs-others contrasts as untrustworthy when corpus coverage may be incomplete.

## 9. Limitations and Integration with `cost-sweep-corpus.sh` v3 schema

This tool depends on a stable method enum and subset stratification. The TTC schema-v1 output is structurally orthogonal to the cost-sweep-corpus v3 schema (different tools, different events read); cross-walks happen externally by joining on `(slug, workstream)` when correlating cost and time. There is no shared file; no schema bump on the cost-sweep side.
