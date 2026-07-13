# tools/recommend.sh

Orchestrates cost, time, and outcome analysis across your session corpus to recommend a Pass the Baton method (`compact`, `clear-only`, `automemory`, or `none`) and an optimal `BATON_PCT_THRESHOLD`.

---

## Quick start

```bash
# Human-readable report (default)
tools/recommend.sh --human

# Raw JSON evidence dump
tools/recommend.sh --json
```

---

## Output sections

### Cost-optimal method

The method with the lowest modeled cost across replayed session transcripts. Cost is computed by `replay_harness` over all four method arms; the arm with the lowest mean cost wins.

### Time-optimal method

The method with the shortest median wall-clock time to complete a session, derived from `time-to-complete-corpus.sh` with `--rigor workshop`.

### Outcome-quality leader

The method with the best aggregate outcome-proxy score from `outcome-proxy-rollup.sh`.

**Insufficient-data clause:** outcome scoring requires at least 30 days of outcome-proxy telemetry. When `post_e16_days < 30` this section reads:

```
Outcome-quality recommendation: insufficient data; N more days needed.
```

where `N = 30 − post_e16_days`. The word "insufficient data" appears in the output exactly when this condition holds.

### Recommended BATON_PCT_THRESHOLD

Threshold sweep result: the value of `BATON_PCT_THRESHOLD` that minimizes median session cost. Sweep baseline is 22; savings are reported relative to that baseline. The current shipped default is 20.

### Paired deltas

Per-pair bootstrap confidence intervals (BCa) for cost differences between method arms. Present only when at least one transcript arm has non-zero cost (`cost_producer_degenerate = false`).

### Caveats

| Caveat key | Meaning |
|---|---|
| `data_age_crossing` | Telemetry window crosses a model release boundary; cost and time comparisons may mix pricing eras. The affected model(s) are listed. |
| `outcome_data_insufficient` | Fewer than 30 days of outcome-proxy telemetry; outcome winner is suppressed. |
| `no_significant_difference` | At least one paired-delta CI straddles zero; no method is statistically superior on cost. |
| `cost_producer_degenerate` | All transcript arms returned zero cost; paired deltas are skipped. |

---

## Flags

| Flag | Default | Description |
|---|---|---|
| `--human` | yes | Human-readable report. |
| `--json` | - | Raw aggregate JSON; useful for scripting or debugging. |
| `--corpus DIR` | `~/.claude/projects` | Transcript corpus directory for the cost sweep. Primarily a test-affordance / power-user flag. |
| `--since DATE` | event-log minimum | Window start date (`YYYY-MM-DD`). Overrides the minimum timestamp derived from the event log. |
| `--log PATH` | `$BATON_EVENT_LOG` or state dir | Events JSONL file used for outcome and time data. Primarily a test-affordance / power-user flag. |
| `--strict-recent` | off | Omits sessions whose `cost_rollup` timestamp predates the release date of the model used in that session. Default behavior passes all sessions through **unweighted** - the 0.5-weighting discussed in earlier design notes is not implemented in this release. |
| `--cost-json PATH` | - | Supply a pre-built cost JSON file instead of running `cost-sweep-corpus.sh`. Bypasses the corpus sweep entirely. Primarily a test-affordance / power-user flag. |

---

## What this tool does not claim

- **No causal inference.** All signals are correlational. A method that scores better on cost or outcome proxies in your corpus may reflect usage patterns, session length, or project mix rather than a direct effect of the checkpoint method.
- **Modeled cost, not billed-cost reconciliation.** Costs are computed by replaying token usage through pricing models. They will not match your Anthropic invoice; factors such as prompt caching, batch discounts, and billing rounding are not captured.
- **Point-in-time snapshot.** The report reflects the corpus and telemetry available at the time of the run. It does not detect drift, compare against prior runs, or track how recommendations change over time.
