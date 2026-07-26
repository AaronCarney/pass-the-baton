---
description: Briefly defer Pass the Baton checkpointing for this session (default 10 minutes).
allowed-tools: Bash
argument-hint: "[minutes]"
---

Snooze checkpointing for this session:

!`bash "${CLAUDE_PLUGIN_ROOT}/tools/baton-snooze.sh" $ARGUMENTS`

If the line above did not print a "snoozed" confirmation, either the plugin root did not resolve OR CLAUDE_CODE_SESSION_ID was not exported into the inline step - in that case run the snooze script yourself now with the Bash tool (where CLAUDE_CODE_SESSION_ID is present), passing the same optional minutes argument: it lives at `${CLAUDE_PLUGIN_ROOT}/tools/baton-snooze.sh`. Then tell the user how long checkpointing is deferred.
