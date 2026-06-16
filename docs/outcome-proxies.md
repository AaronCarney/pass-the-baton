# Outcome-quality proxies

Definitions, opt-in flow, ranking rules, and privacy posture for the four outcome-quality proxy signals. These proxies let the measurement instrument assess session quality without access to ground-truth labels.

---

## Why

Direct outcome labels (did this session produce correct, usable work?) require human judgment and cannot be emitted in-band by a hook layer. Proxy signals derived from observable Claude Code events correlate strongly with outcome quality and are available immediately, locally, and without additional API calls. The four proxies below are ranked by signal fidelity.

---

## The four proxies

### Primary: code-execution success

**What it measures.** Whether tool calls that invoke code execution (bash, run_code, test invocations) exit 0. A session where every code-execution tool call exits cleanly is a strong forward indicator that the artifacts produced were at least structurally sound.

**Event emitted.** `outcome_proxy` with `subkind: "code_execution"`, `success: bool`, `runner: str`, `exit_code: int`, and optionally `session_id: str`.

**Limitation.** Does not distinguish "test ran and passed" from "script ran and produced wrong output silently." Paired with follow-up density (below) to bound false positives.

### Secondary: follow-up density

**What it measures.** The rate of user follow-up messages in the first N turns after an assistant tool-use burst. High follow-up density correlates with correction intent: the user is repairing something that didn't land right.

**Event emitted.** `outcome_proxy` with `subkind: "follow_up"`, `slug: str`, `n_sessions: int`, `n_terminals: int`, `mean_turns_per_session: float`, `total_turns: int`.

**Limitation.** Short sessions have noisy estimates. Minimum window of 4 turns required before the value is emitted.

### Supplementary: commit survival

**What it measures.** Whether commits authored during a session survive (are not reverted, force-reset, or amended out) within a configurable lookback window (default 14 days). A surviving commit is a weak positive signal; a reverted commit is a strong negative signal.

**Event emitted.** `outcome_proxy` with `subkind: "commit_survival"`, `slug: str`, `window_days: int`, `n_commits: int`, `n_reverted: int`, `n_survived: int`, `survival_fraction: float`.

> Note: the shipped `tools/outcome-proxy-commit-survival.sh` uses `git log --since=<N> days ago` rather than `git log --follow`, because git's `--follow` flag requires a pathspec (it tracks file renames across commits) and the slug-keyed per-project counting in this proxy has no meaningful pathspec - it counts commits in the project's window, not file revisions. Code is authoritative here.

**Limitation.** Requires git repo context. Silent if git is unavailable.

### Triage: retry density

**What it measures.** The density of retry-class user turns (turns classified as CORRECTION or CLARIFICATION by the retry-intent classifier, or heuristically matched when the classifier is not bootstrapped). High retry density is a strong negative outcome signal.

**Event emitted.** `outcome_proxy` with `subkind: "retry"`, `similarity: float`, `n_prior_prompts: int`, `session_id: str`.

**Limitation.** Heuristic mode (pre-bootstrap) is noisy. Classifier mode (post-bootstrap) requires `--allow-prompt-export` at bootstrap time. See Retry-intent classifier section below.

---

## Retry-intent classifier

The retry-intent classifier assigns each user turn one of four classes:

| Class | Meaning |
|---|---|
| `EXPLORATION` | New direction, expansion, or feature request - positive signal |
| `CORRECTION` | Fixing something wrong in the prior output - negative signal |
| `CLARIFICATION` | Requesting explanation of prior output (Schegloff repair - neutral-to-negative) |
| `OTHER` | Out-of-band, off-topic, or unclassifiable |

**4-class schema source:** Liu-Zhang-Choi EMNLP 2025 retry-feedback taxonomy (4-class: EXPLORATION/CORRECTION/CLARIFICATION/OTHER). CLARIFICATION maps to Schegloff (1977, 1987) conversational repair - user is asking the assistant to re-do or re-explain, which co-occurs with output failures at a measurable rate above base.

**Bootstrap workflow:**

1. Run `tools/retry-intent-bootstrap.sh` - samples N turns from `hook-events.jsonl`, exports prompt text to a mode-0700 directory.
2. Human labels the exported file (add `label` column: EXPLORATION/CORRECTION/CLARIFICATION/OTHER).
3. Run `tools/retry-intent-classify.sh` - configures the classifier with few-shot examples from the labeled data (default: Haiku LLM-as-judge).
4. Run `tools/retry-intent-promote.sh` - promotes the bootstrapped classifier to active; subsequent sessions use classifier mode rather than heuristic mode.

**LLM-as-judge default (Haiku).** When the bootstrapped data is available, the active classifier calls `claude-haiku-4-5` with the labeled examples as few-shot context. Bias mitigations applied per Mishra/Wang LLM-as-judge guidelines: (a) calibration check on the bootstrap hold-out set before promotion (≥ 0.80 accuracy required); (b) no self-evaluation - the judge model is never the same model being evaluated.

> Known limitation: the shipped `retry-intent-classify.sh` emits classes in a fixed order rather than a position-debiased prompt. Adding randomization would require changes to its prompt construction plus κ re-validation against the bootstrap CSV; it is deferred to a future round focused on classifier rigor (paired with broader bias-mitigation work).

**Promotion gate:** `tools/retry-intent-promote.sh` requires all three promotion thresholds to pass before writing the classifier config (see the ranking rules below).

---

## Opt-in flow

Outcome proxies are **off by default**. To enable:

```bash
export BATON_OUTCOME_PROXIES=1
```

Add to your shell rc file for persistence.

When enabled, outcome proxy events are emitted to `hook-events.jsonl` via three surfaces:

- `code_execution` - `PostToolUse` hook (matcher `Bash`) at `.claude/hooks/outcome-proxy-code-execution.sh`
- `retry` - `UserPromptSubmit` hook at `.claude/hooks/outcome-proxy-retry-density.sh`
- `follow_up` + `commit_survival` - async CLI tools at `tools/outcome-proxy-follow-up.sh` and `tools/outcome-proxy-commit-survival.sh`

These events contain only numeric or structural fields - no prompt text, no file contents. See Privacy posture below.

**Classifier additional opt-in.** The retry-intent classifier bootstrap (`tools/retry-intent-bootstrap.sh`) additionally requires:

```bash
tools/retry-intent-bootstrap.sh --allow-prompt-export
```

This flag is required because the bootstrap samples prompt text for labeling. The exported file is written to a mode-0700 temporary directory and is not included in `hook-events.jsonl`. Once bootstrap is complete and the classifier is promoted, subsequent session runs do NOT export prompt text - the LLM-as-judge call sends only the user turn text, not the full session context.

---

## Ranking rules

The measurement instrument ranks methods by outcome quality using a weighted combination of proxy scores. The ranking thresholds are:

| Proxy | Weight | Minimum threshold for inclusion |
|---|---|---|
| code_execution | 0.40 | ≥ 0.60 (< 0.60 = excluded from ranking) |
| follow_up | 0.25 | no minimum (penalizes as-is) |
| commit_survival | 0.20 | data required (silent if git unavailable) |
| retry | 0.15 | no minimum (penalizes as-is) |

**Classifier promotion gate.** Before `tools/retry-intent-promote.sh` writes the active classifier config, all three gates must pass:

- **Cohen's κ ≥ 0.70** on the bootstrap hold-out set (load-bearing tier).
- **Held-out accuracy ≥ 0.80** overall on the hold-out set (load-bearing tier).
- **macro-F1 ≥ 0.65** across all four classes (load-bearing tier - guards against majority-class collapse).

**Supplementary tier:** κ ∈ [0.40, 0.70) OR accuracy ∈ [0.60, 0.80). **Triage tier:** all other results.

If any load-bearing gate fails, `retry-intent-promote.sh` exits non-zero and prints which gate failed with its observed value.

**Roll-up aggregation.** `tools/outcome-proxy-rollup.sh` aggregates per-subkind events (no cross-subkind mean conflation per F7), computes success rates and means grouped by method/subset/subkind, and emits a ranked JSON structure.

---

## Event schema

All `outcome_proxy` events share a common envelope and a per-subkind payload:

```
event='outcome_proxy', data.subkind ∈ {code_execution, retry, follow_up, commit_survival}.

code_execution: {subkind, success: bool, runner: str, exit_code: int, session_id?: str}
retry: {subkind, similarity: float, n_prior_prompts: int, session_id: str}
follow_up: {subkind, slug: str, n_sessions: int, n_terminals: int, mean_turns_per_session: float, total_turns: int}
commit_survival: {subkind, slug: str, window_days: int, n_commits: int, n_reverted: int, n_survived: int, survival_fraction: float}

Envelope (top-level, all events): {schema_version: int, event: str, ts: str (ISO-8601 UTC), data: object} - note the timestamp field is `ts`, NOT `timestamp`, per shipped .claude/hooks/lib/envelope.sh:99.
```

The prior doc revision referenced several fictional field names that were never emitted by the shipped code (a generic float value, a plural integer array of exit codes, a 7-char commit hash string, and a generic type discriminator). None of these exist in any hook output; the actual subkind discriminator is the `subkind` field documented above.

---

## Privacy posture

**Fields emitted in `outcome_proxy` events (per subkind):**

- `subkind` - string identifier (`code_execution`, `retry`, `follow_up`, `commit_survival`)
- `success` - bool (code_execution only)
- `runner` - string (code_execution only)
- `exit_code` - integer (code_execution only)
- `session_id` - hash, not raw path (code_execution + retry)
- `similarity` - float (retry only)
- `n_prior_prompts` - integer (retry only)
- `slug` - project slug (follow_up + commit_survival)
- `n_sessions`, `n_terminals`, `mean_turns_per_session`, `total_turns` - integers/float (follow_up only)
- `window_days`, `n_commits`, `n_reverted`, `n_survived`, `survival_fraction` - integers/float (commit_survival only)

**Fields that NEVER appear in `outcome_proxy` events:**

- Prompt text
- File contents
- Tool call arguments
- Environment variable values
- File paths (only hashed session_id)

**Classifier bootstrap is the one exception.** `tools/retry-intent-bootstrap.sh --allow-prompt-export` writes prompt text to a mode-0700 temporary directory for human labeling. This file:
- is not appended to `hook-events.jsonl`,
- is not sent to any remote endpoint,
- must be explicitly named as the input to `retry-intent-classify.sh`,
- is deleted by `retry-intent-promote.sh` after successful promotion.

**Sentinel-grep regression gate.** `.claude/hooks/tests/test-outcome-proxy-privacy.sh` asserts that no `outcome_proxy` event in the test fixtures contains prompt-text-shaped content. This test is part of the standard suite and must pass on every commit touching outcome-proxy emitters.

---

## Roll-up tool usage

```bash
# Compute outcome-proxy aggregate stats for all sessions in JSONL
tools/outcome-proxy-rollup.sh --log hook-events.jsonl

# Specify transcripts directory
tools/outcome-proxy-rollup.sh --transcripts-dir ~/.local/share/baton/transcripts

# Use a projects-state file
tools/outcome-proxy-rollup.sh --projects-state projects.json

# JSON output (default: human-readable table)
tools/outcome-proxy-rollup.sh --log hook-events.jsonl --json
```

Real flags: `--log`, `--status-file`, `--projects-state`, `--transcripts-dir`, `--json`. Flags referenced in the prior doc revision (`--input`, a `--method` comparison flag, and `--train`) do not exist in the shipped tool.

---

## Citations

- Don-Yehiya S. et al. 2024. LLM annotation with inter-rater agreement calibration. - Kappa baseline context for LLM-as-judge annotation reliability.
- Liu Y., Zhang T., Choi E. EMNLP 2025. Retry-feedback taxonomy for conversational agents (4-class: EXPLORATION/CORRECTION/CLARIFICATION/OTHER). - 4-class schema source.
- Schegloff E.A. 1977. Sequence organization in interaction. Cambridge University Press. - conversational repair; foundational source for CLARIFICATION class.
- Schegloff E.A. 1987. Some sources of misunderstanding in talk-in-interaction. Linguistics 25. - repair-initiation patterns.
- Mishra S., Wang A. 2023. Is LLM a good evaluator? LLM-as-judge bias patterns and mitigations. - position-debiasing + calibration-check mitigations.
- Measurement-instrument proxy-ranking constraints.
- Subset stratification and retry-density classifier protocol.
