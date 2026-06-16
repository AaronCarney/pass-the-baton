# Integration Patterns

Three concrete recipes for wiring Pass the Baton into an existing project layout. Each pattern lists rationale, exact bash, and a verification command.

## Pattern A - Dynamic display names from project layout

**Use when:** you want workstream display names derived from `$PWD` or the current git branch, not the auto-generated timestamp.

**Rationale:** `BATON_DISPLAY_NAME` is read at `claude` launch time. Setting it once in `~/.bashrc` gives a static value; setting it from a `cd` / `git checkout` hook gives a value that tracks your context. This pattern was used internally before the OSS decoupling; the checkpoint code itself is layout-agnostic.

**Bash (shell rc):**

```bash
# Append to ~/.bashrc (or ~/.zshrc).
_claude_checkpoint_display_name() {
  local branch base
  branch=$(git -C "$PWD" symbolic-ref --short HEAD 2>/dev/null)
  base=$(basename "$PWD")
  if [ -n "$branch" ]; then
    export BATON_DISPLAY_NAME="${base}:${branch}"
  else
    export BATON_DISPLAY_NAME="$base"
  fi
}

# Re-evaluate on every prompt (cheap; ~1ms).
PROMPT_COMMAND="_claude_checkpoint_display_name; $PROMPT_COMMAND"
```

**Verify:**

```bash
cd ~/myproject && claude
# Inside Claude Code:
# Run:  echo "$BATON_DISPLAY_NAME"
# Expected: myproject:main (or whatever branch you're on)
```

## Pattern B - Archives on a different volume

**Use when:** you have a large external disk and want archives there instead of `$HOME`.

**Rationale:** archives accumulate over months. Keeping them off the boot volume avoids `$HOME` bloat.

**Bash (shell rc):**

```bash
# Append to ~/.bashrc.
export BATON_ARCHIVE_DIR="/mnt/data/baton"
```

**Cron env file** (cron does not inherit shell rc - must also live in the env file):

```bash
# ~/.config/baton/env (managed by tools/install-cron.sh, regenerated on install --reconfigure)
export BATON_ARCHIVE_DIR="/mnt/data/baton"
```

**Verify:**

```bash
ls -d /mnt/data/baton/checkpoint-state/$(date +%Y-%m)/workstreams 2>/dev/null && echo "OK"
```

## Pattern C - Existing statusline; just want the checkpoint trigger

**Use when:** you already have a custom statusline command in `~/.claude/settings.json` and don't want to replace it.

**Rationale:** `assets/baton-pct.sh` is the trigger source: it writes `/tmp/claude-context-pct-${SESSION_ID}` each tick, and the pre-tool-use hook reads from that file. Compose, don't replace.

**Bash (statusline command snippet in settings.json):**

Replace `/path/to/baton` with the absolute path of your cloned repo (the directory containing `tools/install.sh`). Pass the Baton does not export an install-dir env var - by design, so it doesn't pollute your shell rc - so the path is literal here.

```jsonc
{
  "statusline": {
    "type": "command",
    "command": "bash -c 'bash /path/to/baton/assets/baton-pct.sh; bash $HOME/.claude/your-existing-statusline.sh'"
  }
}
```

If you want to avoid hard-coding the absolute path, set your own env var in your shell rc (e.g., `export BATON_REPO=/abs/path`) and reference `$BATON_REPO` in the snippet. `$CLAUDE_PROJECT_DIR` (set by Claude Code at runtime) points at the consumer project, not the Pass the Baton repo - they are different directories.

**Verify:**

```bash
ls -lt /tmp/claude-context-pct-* 2>/dev/null | head -3
# Expected: one entry per active Claude Code session, mtime within seconds.
```

## Filename contract

Progress files are matched by the literal pattern `progress-*.md` in `.claude/hooks/checkpoint-write-trigger.sh`. This is contract, not configurable. Consumers with their own naming convention (`notes-YYYY-MM-DD.md`, `journal-*.md`, etc.) must either:

1. Adopt the `progress-` prefix for files you want auto-archived, or
2. Maintain a small adapter (e.g., a symlink `progress-foo.md → notes-foo.md`) that the trigger sees.

Filenames that don't match are silently rejected - check `jq -c 'select(.event=="basename-reject")' "$BATON_DIR/hook-events.jsonl"` if archiving isn't happening as expected.
