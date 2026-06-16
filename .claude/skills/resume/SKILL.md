---
name: resume
description: Rebind this terminal to a different workstream. Use after reboot, crash, or to manually switch.
---

# Resume - Workstream Recovery

## When to Use

- New terminal after a crash or reboot
- Terminal that needs to switch to a different workstream
- Any session that started on the wrong workstream
- Recovery from an archived workstream (idle >7 days)

## Process

### Step 1: List Active + Archived Workstreams

Run the canonical CLI and show its output:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/tools/resume.sh" --list
```

Output shows numbered active workstreams (sorted newest first) followed by archived ones from the last 30 days (tagged `(archived)`). If both lists are empty, the CLI prints an empty-state hint pointing at `docs/install.md` - relay it and stop.

Ask the user to pick by workstream id (the `workstream: <id>` field shown next to each entry).

### Step 2: Rebind This Terminal

Run the CLI with the chosen id:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR}/tools/resume.sh" "<chosen-workstream-id>"
```

The CLI handles all of:
- archive restore (delegates to `tools/restore-workstream.sh` if not currently active)
- terminal rebinding (rewrites `terminals/<term_hash>.json`)
- bumping `workstreams/<ws>.updated_at`

On success, the CLI prints `Bound this terminal to <ws>.` to stderr and exits 0.

### Step 3: Read Progress File

Read the `progress_file` path from `$(checkpoint_dir)/workstreams/<chosen-ws>.json`. If the file exists, read and present it. If empty, note that the workstream is fresh. If set but missing, note the previous session may have crashed mid-checkpoint.

### Step 4: Gap Analysis

Run these commands and present the results:

1. **Git state since checkpoint:**
   ```bash
   git log --oneline -10
   git status -s
   git stash list
   ```

2. **Compare against progress file:** if the progress file lists "tasks done" with commit hashes, verify those commits exist. Flag any listed-as-done that are missing from the log.

3. **Uncommitted work:** if `git status -s` or `git stash list` show changes, surface them.

### Step 5: Report and Confirm

Present a summary with workstream id/phase/last-checkpoint timestamp and the gap analysis. Ask: "Ready to continue, or review the uncommitted changes first?"

## Important

- This skill ONLY handles workstream rebinding and gap analysis.
- It does NOT start implementation - the user decides what to do after reviewing the gap.
- It does NOT touch `/tmp` files. Identity is computed via `workstream-lib.sh::term_hash`.
- The CLI at `tools/resume.sh` is the canonical implementation. This skill is a Claude Code wrapper around it. Consumers who don't use Claude Code can invoke the CLI directly.
