# Pass the Baton - Install Guide

## Platform Support

- **Linux** (Ubuntu, Debian, Fedora, Arch) - primary target.
- **WSL2** - supported (mirrored networking; statusline shim writes to /tmp inside WSL).
- **macOS / BSD** - *deferred.* `project-detect.sh` uses GNU `grep -P \K`; `cleanup-cron.sh` uses GNU `find -mmin`. Both have BSD equivalents but are not currently tested.

## Dependencies

### Required (core hooks)

| Tool | Min version | Purpose |
|---|---|---|
| `bash` | 4.4 | associative arrays, `[[ ]]`, safe empty-array expansion under `set -u` |
| `jq` | 1.6 | all state-file mutations |
| `flock` | util-linux 2.30 | workstream-record write serialization |
| `grep` | GNU 3 | `\K` PCRE in project-detect |
| `find` | GNU 4.7 | `-mmin`/`-newer` semantics in cleanup-cron |
| `md5sum` | coreutils 8 | terminal-hash derivation |

### Optional (analysis tools)

These unlock specific CLI surfaces beyond the core hooks. `install.sh` warns if any are missing but does not block the install.

| Tool | Required by | Install |
|---|---|---|
| `duckdb` | `tools/query.sh` (SQL over `hook-events.jsonl`) | binary at duckdb.org or `brew install duckdb` / `apt install duckdb` |
| `bc` | `lib/recommend-threshold-sweep.sh` (`tools/recommend.sh` dependency) | `apt install bc` / preinstalled on most distros |
| `python3` ≥ 3.10 + `pip install -r requirements.txt` | `tools/recommend.sh`, `tools/cost-compare.sh`, hierarchical-model + bootstrap stats | `python3 -m pip install -r requirements.txt` (numpy / scipy / pymc / bambi / matplotlib / scikit-learn - heavy, ~minutes to install) |

See [`.claude/hooks/tests/PREREQS.md`](../.claude/hooks/tests/PREREQS.md) for the verification commands.

## Environment Variables

See [`context-baton.md` § Configuration](context-baton.md#configuration-env-vars) for the full table.

## Install Steps

### Recommended: install as a Claude Code plugin

```
/plugin marketplace add AaronCarney/pass-the-baton
/plugin install pass-the-baton@pass-the-baton
```

This wires the hooks + skills; the cleanup sweep runs automatically on session start (no cron needed). Restart Claude Code so the hooks load. The optional statusline indicator and interactive directory setup are not part of the plugin install - use the `install-baton` skill or the manual steps below for those.

The manual `tools/install.sh` flow below remains supported as a non-plugin / scripted fallback.

### 1. Clone the repo

```bash
git clone https://github.com/<your-fork>/pass-the-baton ~/pass-the-baton
cd ~/pass-the-baton
```

### 2. Run the installer

```bash
bash tools/install.sh --target /path/to/your/project
```

The installer:
- validates dependencies (jq, flock, GNU grep/find, md5sum, bash 4.4+),
- walks you through 5 first-time-setup prompts (interactive mode - default when stdin is a TTY),
- merges 10 hook commands into `~/.claude/settings.json` (idempotent - re-run is a no-op): via `merge-settings.sh` - SessionStart, PreToolUse, PostToolUse (checkpoint-write + the opt-in `outcome-proxy-code-execution`), SessionEnd, UserPromptSubmit (project-detect + the opt-in `outcome-proxy-retry-density`); plus three inline jq blocks - PostToolBatch (`post-tool-batch`, cost telemetry), PostToolUse:`tool-timing`, and SubagentStop (`post-subagent-cost`). The two outcome-proxy hooks no-op unless `BATON_OUTCOME_PROXIES=1`,
- copies the statusline shim to `~/.claude/baton-pct.sh`,
- appends `.baton/` to the target project's `.gitignore`,
- prints an optional crontab line (the cleanup sweep already runs automatically on session start; the crontab is only a fallback for machines where Claude Code sessions are infrequent).

### 3. Verify

```bash
bash tools/verify-install.sh
```

Exit 0 = healthy.

## 4. Outcome-quality proxies (opt-in)

Outcome-quality proxies are **off by default** and require an explicit opt-in:

```bash
export BATON_OUTCOME_PROXIES=1
```

When enabled, outcome proxy events are emitted to `hook-events.jsonl` via three surfaces:

- `code_execution` - `PostToolUse` hook (matcher `Bash`) at `.claude/hooks/outcome-proxy-code-execution.sh`
- `retry` - `UserPromptSubmit` hook at `.claude/hooks/outcome-proxy-retry-density.sh`
- `follow_up` + `commit_survival` - async CLI tools at `tools/outcome-proxy-follow-up.sh` and `tools/outcome-proxy-commit-survival.sh`

Four proxies are recorded:

| Proxy | Signal |
|---|---|
| `code_exec` | Code-execution exit codes - primary quality signal |
| `followup_density` | Rate of correction-intent user follow-ups - secondary |
| `commit_survival` | Whether session commits survive 24 h - supplementary |
| `retry_density` | Fraction of user turns classified as retry-class - triage |

All event payloads are numeric or structural only (no prompt text, no file contents).

**Retry-intent classifier.** The `retry_density` proxy can operate in heuristic mode (no extra setup) or classifier mode (higher fidelity). To bootstrap the classifier:

```bash
tools/retry-intent-bootstrap.sh --allow-prompt-export
# label the exported file (add label column), then:
tools/retry-intent-classify.sh
tools/retry-intent-promote.sh
```

The `--allow-prompt-export` flag is required because the bootstrap samples prompt text for labeling. Once promoted, subsequent sessions do not export prompt text.

See [`docs/outcome-proxies.md`](outcome-proxies.md) for proxy definitions, the ranking rules, and full privacy posture.

## Hook Coexistence

Checkpoint hooks are append-only against your existing settings.json `hooks` arrays. Ordering does not affect correctness - verify by checking `$(checkpoint_dir)/hook-events.jsonl` for `event=PreToolUse` entries (the threshold-cross trigger; see `context-checkpoint.sh`) after a session crosses the 23% threshold.

## First-time Setup

The installer asks 5 questions. Defaults are sensible for the common case; override when your layout differs.

> **Note:** the prompt text below is verbatim from `tools/install.sh`. A CI check (`test-prompt-sync.sh`) enforces this. If you're editing one, edit the other.

<!-- PROMPT-SYNC-BEGIN -->

### 1. `BATON_DIR`

```
Where should checkpoint state live? (BATON_DIR)
  This is the directory holding workstreams/, terminals/, and progress/.
```

- **Default:** `$TARGET/.baton`
- **Override when:** you want state on a different volume, or under a path your project already tracks (e.g. `$TARGET/state/baton`).
- **Shell rc:** `export BATON_DIR="/your/path"`

### 2. `BATON_PROGRESS_DIR`

```
Where should progress files live? (BATON_PROGRESS_DIR)
  Resume injects the most recent file from here at SessionStart.
```

- **Default:** `$BATON_DIR/progress`
- **Override when:** your project already keeps session notes in a dedicated directory and you want progress files commingled there.
- **Shell rc:** `export BATON_PROGRESS_DIR="/your/path"`

### 3. `BATON_ARCHIVE_DIR`

```
Where should pruned workstreams be archived? (BATON_ARCHIVE_DIR)
  Idle >7d records move here. Recoverable via /resume.
```

- **Default:** `$HOME/.local/share/baton` (XDG)
- **Override when:** archives should live on an external disk or shared storage.
- **Shell rc:** `export BATON_ARCHIVE_DIR="/your/path"`

### 4. `BATON_PROJECT_DIR`

```
What is the project root cron should operate on? (BATON_PROJECT_DIR)
  Cleanup-cron runs out-of-shell; needs this fixed at install time.
```

- **Default:** `$PWD` at install time
- **Override when:** cron should always operate on a fixed path (e.g. `/srv/projects/foo`) regardless of where you cd.
- **Shell rc:** `export BATON_PROJECT_DIR="/your/path"`

### 5. `BATON_DISPLAY_NAME` (optional)

```
Optional: how should this terminal name its workstream? (BATON_DISPLAY_NAME)
  Examples - basename: "${PWD##*/}"   git branch: "$(git symbolic-ref --short HEAD 2>/dev/null)"
  Leave blank for the auto-generated timestamp name.
```

- **Default:** empty → auto-generated timestamp name
- **Override when:** you want display names derived from PWD or git branch. **Read at `claude` launch time** - re-export between sessions (e.g. from a `cd` hook) for the value to change with directory.
- **Shell rc:** `export BATON_DISPLAY_NAME="$(basename "$PWD")"`

<!-- PROMPT-SYNC-END -->

## Verify After Install

```bash
bash tools/verify-install.sh
```

Checks: each of the 5 core hook events (SessionStart, PreToolUse, PostToolUse, SessionEnd, UserPromptSubmit) has a checkpoint hook registered, statusline tick file appears within ~1s, full test suite passes (102 test scripts), idempotency re-run is a no-op.

`--pre-commit-only` runs the S2 smoke (E1-only path) for fast pre-commit gating.

## Uninstall

```bash
bash tools/uninstall.sh
```

- strips all 10 of our hook commands from `~/.claude/settings.json` (user entries untouched),
- archives `$BATON_DIR/` to `$BATON_ARCHIVE_DIR/uninstall-<timestamp>/`,
- prints the crontab line to remove.

Pass `--target /path/to/your/project` for a **full** uninstall that also:

- removes the `.baton/` line from your project's `.gitignore` (the inverse of the `.gitignore` append the installer performs),
- removes the cron wrapper (`tools/cleanup-cron-wrapper.sh`) and env file (`$XDG_CONFIG_HOME/baton/env`).

The two-mode design is deliberate: a soft uninstall (no `--target`) only touches your settings.json so a stray `bash tools/uninstall.sh` from an unrelated working directory can never rewrite that repo's `.gitignore` or delete an installer-managed file under `$REPO_DIR`.
