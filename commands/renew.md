---
description: Save a checkpoint now and hand off early (baton renew), as if the context threshold were reached.
allowed-tools: Bash
---

Arm an immediate checkpoint for this session:

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/baton-checkpoint-now.sh"`

If the line above did not print a "checkpoint armed" confirmation, either the plugin root did not resolve OR CLAUDE_CODE_SESSION_ID was not exported into the inline step - in that case run the arm script yourself now with the Bash tool, where CLAUDE_CODE_SESSION_ID is present: it lives at `${CLAUDE_PLUGIN_ROOT}/tools/baton-checkpoint-now.sh` (the pass-the-baton plugin install directory). Then write the checkpoint progress file for this session, following the standard checkpoint protocol the hook injects on your next tool action. Prepare the handoff first; do not continue unrelated work.
