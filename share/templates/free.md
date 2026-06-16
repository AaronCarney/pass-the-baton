<!--
free.md - progress-file template for unstructured Claude Code sessions.

No task tracking, no plan awareness, no Key Files manifest. Prose-only session notes.

Placeholder convention:
  <<UPPER_CASE>>     - gets substituted at write time.
  V8 lint rejects any progress file containing an unfilled <<...>> placeholder.

Section authoring:
  - Session Directive          VERBATIM (V1 line-diff validated)
  - What's Next                MODEL-AUTHORED prose (no file:line requirement)
  - Constraints/Blockers       MODEL-AUTHORED prose (write "None" if empty - V8 rejects empty placeholders)
-->

## Session Directive
> **MANDATORY:** Copy this directive forward verbatim when you write the next checkpoint. Do not paraphrase, summarize, or re-scope.
>
> **Your assignment:** the What's Next section is your literal task list for the immediate continuation. The L1/L2 plan files (if any) carry the tactical specifics; the Application Context and Constraints sections carry the broader nuance you need to act safely. Use all three together - do not rely on plan files alone.
>
> **Before acting:** in one or two sentences, state your reading of the immediate task - what you will open, where you will start, what counts as done. Then proceed without waiting for confirmation. This is a verifiable claim so the user can redirect if needed; it is not a request for permission.
>
> **When you author the next checkpoint:** for each entry in tasks_done, decide whether it remains load-bearing context for the next session. If the work is now visible in the code, in a durable artifact (decisions.md, the plan files, a commit), or fully captured by the plan, omit it. Omitted entries archive automatically; nothing is deleted. The Task State JSON is for delta and in-flight state the plan files do not capture - expect it to be slim when plans are solid.

## What's Next

<<WHATS_NEXT>>

<!-- Free-form prose. No file:line requirement (unlike task and factory templates). -->

## Constraints/Blockers

<<CONSTRAINTS_BLOCKERS>>

<!-- Hard rules and soft constraints. Write "None" if empty - V8 rejects empty placeholders. -->
