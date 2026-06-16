<!--
task.md - progress-file template for semi-structured project work outside a formal L1/L2 plan.

Markdown task list (checkboxes), Key Files manifest, no JSON Task State block.

Placeholder convention:
  <<UPPER_CASE>>     - gets substituted at write time.
  V8 lint rejects any progress file containing an unfilled <<...>> placeholder.

Section authoring:
  - Session Directive          VERBATIM (V1 line-diff validated)
  - What's Next                MODEL-AUTHORED prose (V7 requires ≥1 file:line reference)
  - Application Context        MODEL-AUTHORED prose
  - Position                   HOOK-FILLED from workstream record + git
  - Key Files                  HOOK-FILLED via project-context resolver, then MODEL-APPENDED for task-specific files
  - Task State                 MODEL-AUTHORED markdown checkbox list. Done items use [x]; pending items use [ ]. The write-trigger hook moves [x] items to ## Archived automatically - do not manually delete them.
  - Archived                   HOOK-FILLED at render (copies prior ## Archived body or "None yet"). Don't author.
  - Constraints/Blockers       MODEL-AUTHORED prose (write "None" if empty - V8 rejects empty placeholders)
  - Git State                  HOOK-FILLED from `git log` + `git status`
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

<!-- V7 lint: this section must contain at least one file-path-with-line-number reference (e.g., `lib/foo.sh:42`). -->

## Application Context

<<APPLICATION_CONTEXT>>

<!-- Brief project description - what the project does, the cycle's current focus, anything not visible from code or docs but needed by the next session. -->

## Position

- Workspace: `<<WORKSPACE_PATH>>`
- Branch: `<<BRANCH>>`
- HEAD: `<<HEAD_SHA>>`
- Phase: <<PHASE>>
- Workstream: `<<WORKSTREAM_ID>>` (display name `<<DISPLAY_NAME>>`)

<!-- V7 lint: `Branch:` and `HEAD:` lines are required. -->

## Key Files

<<KEY_FILES_MANIFEST>>

<!-- Role-labeled manifest from the project-context resolver. Append task-specific rows after the resolver-rendered rows. -->

## Task State

<<TASK_STATE_CHECKBOXES>>

<!--
Markdown checkbox list. Pending items as `- [ ] description`. Done items as `- [x] description`. The write-trigger hook moves `[x]` items into ## Archived at write time - never manually delete.

Example shape:
  - [ ] T1 - implement auth middleware (lib/auth.sh:42)
  - [x] T2 - fix cost-compare sweep boundary
-->

## Archived

<<ARCHIVED_CHECKBOXES>>

<!-- HOOK-FILLED. Auto-substituted at render time: copies the prior progress file's ## Archived section body, or the literal "None yet" on first checkpoint. Don't author manually. The write-trigger hook then moves any newly-completed [x] items here post-lint. -->

## Constraints/Blockers

<<CONSTRAINTS_BLOCKERS>>

<!-- Hard and soft constraints. Write "None" if empty - V8 rejects empty placeholders. -->

## Git State

```
$ git log --oneline -10
<<GIT_LOG>>

$ git status -s
<<GIT_STATUS>>
```
