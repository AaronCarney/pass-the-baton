#!/usr/bin/env bash
# tool-policy.sh - classify a tool for checkpoint gating and build the
# "available vs gated" announcement. Read-only orientation tools are ALWAYS
# allowed (conversation/orientation is never blocked); everything else is gated.
# Functions only; fail-closed on unknown/empty names.

# Read-only tools cannot advance work or lose in-flight state, so they stay open
# even with a checkpoint owed. TodoWrite is local bookkeeping; WebFetch/WebSearch
# are read-only w.r.t. the workspace and part of orientation/research.
_TOOLPOLICY_READONLY_RE='^(Read|Grep|Glob|LS|NotebookRead|TodoWrite|WebFetch|WebSearch)$'

toolpolicy::is_readonly() {  # <tool_name> -> rc0 if read-only
  [[ "$1" =~ $_TOOLPOLICY_READONLY_RE ]]
}

toolpolicy::classify() {  # <tool_name> -> prints 'allow' | 'gate'
  if toolpolicy::is_readonly "$1"; then printf 'allow'; else printf 'gate'; fi
}

toolpolicy::announce() {  # -> one-line open-vs-gated announcement
  printf '%s' 'Read-only tools (Read/Grep/Glob/LS/NotebookRead/WebFetch/WebSearch) stay available so you can keep orienting. Consequential tools (Write/Edit/Bash/Task/...) are gated until the checkpoint is resolved.'
}
