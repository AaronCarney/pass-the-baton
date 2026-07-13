---
name: install-baton
description: Walk the user through Pass the Baton first-time setup, then run tools/install.sh with their answers. Generic OSS install assistant. Pauses for confirmation before each durable write (statusline, crontab).
---

# Install Pass the Baton - First-time Setup Assistant

## When to Use

- User wants to install Pass the Baton into a project.
- Re-configuring BATON_* env vars after a layout change.
- Note: the fastest install is the Claude Code plugin (`/plugin install pass-the-baton@pass-the-baton`); use this skill when you also want the statusline indicator or interactive directory setup.

## Process

### Step 1: Locate the repo

Confirm the user has cloned the Pass the Baton repo. If they haven't, offer to clone it to `~/pass-the-baton`:

```bash
git clone https://github.com/AaronCarney/pass-the-baton.git ~/pass-the-baton
```

If they have cloned it, ask for the absolute path. Treat that path as `<repo>` for the rest of the skill.

### Step 2: Smart-detect the --target

The target is the project the user invoked Claude from - the repo where they spend Claude Code sessions - NOT the clone of Pass the Baton itself. Default: `$PWD` at skill invocation time. If `$PWD` is inside the Pass the Baton clone, walk up to the parent project or ask the user.

### Step 2b: Present the 5 setup questions

Ask each in turn using your question UX. Defaults shown below. The prompt text is **canonical** - it matches `tools/install.sh` and `docs/install.md` verbatim (CI-enforced).

<!-- PROMPT-SYNC-BEGIN -->

#### Q1 - `BATON_DIR`

```
Where should checkpoint state live? (BATON_DIR)
  This is the directory holding workstreams/, terminals/, and progress/.
```

Default: `$TARGET/.baton`

#### Q2 - `BATON_PROGRESS_DIR`

```
Where should progress files live? (BATON_PROGRESS_DIR)
  Resume injects the most recent file from here at SessionStart.
```

Default: `$BATON_DIR/progress`

#### Q3 - `BATON_ARCHIVE_DIR`

```
Where should pruned workstreams be archived? (BATON_ARCHIVE_DIR)
  Idle >7d records move here. Restore a known id with tools/restore-workstream.sh.
```

Default: `$HOME/.local/share/baton`

#### Q4 - `BATON_PROJECT_DIR`

```
What is the project root cron should operate on? (BATON_PROJECT_DIR)
  Cleanup-cron runs out-of-shell; needs this fixed at install time.
```

Default: `$PWD` at install time

#### Q5 - `BATON_DISPLAY_NAME` (optional)

```
Optional: how should this terminal name its workstream? (BATON_DISPLAY_NAME)
  Examples - basename: "${PWD##*/}"   git branch: "$(git symbolic-ref --short HEAD 2>/dev/null)"
  Leave blank for the auto-generated timestamp name.
```

Default: empty (auto-generated timestamp)

<!-- PROMPT-SYNC-END -->

### Step 3: Run the installer

With the 5 values collected, run:

```bash
BATON_DIR="<q1-answer>" \
BATON_PROGRESS_DIR="<q2-answer>" \
BATON_ARCHIVE_DIR="<q3-answer>" \
BATON_PROJECT_DIR="<q4-answer>" \
BATON_DISPLAY_NAME="<q5-answer>" \
bash <repo>/tools/install.sh --non-interactive --target "<q4-answer>"
```

Relay the installer's output to the user verbatim. Treat installer non-zero exit as a stop - surface the error and do not proceed to Step 4.

### Step 4: Wire the statusline (durable write - confirm before applying)

The statusline shim at `<repo>/assets/baton-pct.sh` emits `CTX:NN%` for use in `~/.claude/settings.json`'s `statusLine.command`. Read the user's current setting:

```bash
jq -r '.statusLine.command // empty' ~/.claude/settings.json
```

If empty: the new command will be `bash <repo>/assets/baton-pct.sh "$SESSION_ID"`. If non-empty: COMPOSE - append the shim to the existing command separated by a space (do NOT replace silently). Show the user the BEFORE and AFTER of the `statusLine.command` value and ask:

> 'Apply this change to ~/.claude/settings.json? (yes/no) - this is a durable write.'

Only proceed on explicit affirmative. On yes: back up the settings file (`cp ~/.claude/settings.json ~/.claude/settings.json.bak`), then write the composed value atomically with `jq` + `mv` from a tmp file. On no: skip this step and report 'statusline not wired; user can run /baton set later'.

### Step 5: Install the crontab line (durable write - confirm before applying)

The cleanup-cron sweeps stale workstreams every 2 days. Check whether the line is already present:

```bash
crontab -l 2>/dev/null | grep -q cleanup-cron-wrapper && echo present || echo absent
```

If present: skip. If absent: compute the line:

```bash
LINE="0 3 */2 * * bash <repo>/tools/cleanup-cron-wrapper.sh >/dev/null 2>&1"
```

Show the user the line and ask:

> 'Append this line to your crontab? (yes/no) - this is a durable write.'

Only proceed on explicit affirmative. On yes: `(crontab -l 2>/dev/null; echo "$LINE") | crontab -`. On no: detect systemd user units (`systemctl --user list-unit-files | grep -q Pass the Baton`); if available offer that path; otherwise report 'cleanup-cron not installed; user can re-run install-baton later or schedule it manually'.

### Step 6: Verify

```bash
bash <repo>/tools/verify-install.sh
```

If exit 0: report success, list the env-file path, the statusline status, and the crontab status. If non-zero: surface the failing check verbatim.

### Step 7: End-of-flow

Close with the literal line:

> For ongoing tuning, run `/baton`.

## Important

- This skill is OSS-generic. No project-specific assumptions.
- The 5 prompt blocks above are CI-enforced to byte-match `tools/install.sh` and `docs/install.md`. Edit one, edit all three.
- Users without Claude Code (or who prefer a scripted install) can run `bash tools/install.sh --interactive` directly for the same flow; plugin users get the hooks via `/plugin install` and only need this skill for the statusline.
- Each durable-write step (statusline, crontab) has its own confirm - do NOT bundle them. The rest of the flow is autonomous with defaults.
