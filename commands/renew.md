---
description: Save a checkpoint now and hand off early (baton renew) - writes the progress file, then clears.
allowed-tools: Bash
---

Arm an immediate checkpoint for this session:

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/baton-checkpoint-now.sh"`

If the line above did not print a "checkpoint armed" confirmation, either the plugin root did not resolve OR CLAUDE_CODE_SESSION_ID was not exported into the inline step - in that case run the arm script yourself now with the Bash tool, where CLAUDE_CODE_SESSION_ID is present: it lives at `${CLAUDE_PLUGIN_ROOT}/tools/baton-checkpoint-now.sh` (the pass-the-baton plugin install directory). Then write the checkpoint progress file for this session, following the standard checkpoint protocol the hook injects on your next tool action. Prepare the handoff first; do not continue unrelated work.

Invoking this command **is** the decision to hand off. Write the progress file, then do what `/clear` does: end this session so a new one starts. Do not ask the user whether they would rather keep working - they answered that by running the command. See `docs/context-baton.md` § Checkpoint Modes, case 1B.

Known gap until the mode fix lands: the post-write hook still emits a "Keep working in this session, or clear now?" prompt on this path. That prompt is the superseded trigger-based split, not the intended behavior.
