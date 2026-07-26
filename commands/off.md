---
description: Fully disable Pass the Baton checkpointing for this session (all the way off).
allowed-tools: Bash
---

Disable checkpointing for this session:

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/baton-unlock.sh"`

If the line above did not print a "checkpointing disabled" confirmation, either the plugin root did not resolve OR CLAUDE_CODE_SESSION_ID was not exported into the inline step - in that case run the unlock script yourself now with the Bash tool, where CLAUDE_CODE_SESSION_ID is present: it lives at `${CLAUDE_PLUGIN_ROOT}/tools/baton-unlock.sh`. Then tell the user checkpointing is off for this session and a new session re-enables it.
