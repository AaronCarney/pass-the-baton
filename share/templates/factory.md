<!--
factory.md - progress-file template for software-factory workflows.

Renders into a hybrid markdown + embedded JSON progress file with full L1/L2/L3 plan awareness.

Placeholder convention:
  <<UPPER_CASE>>     - gets substituted at write time.
  V8 lint rejects any progress file containing an unfilled <<...>> placeholder.

Section authoring:
  - Session Directive          VERBATIM (V1 line-diff validated; copy forward without modification)
  - What's Next                MODEL-AUTHORED prose (V7 requires ≥1 file:line reference)
  - Application Context        MODEL-AUTHORED prose
  - Position                   HOOK-FILLED from workstream record + git
  - L1 Context                 HOOK-FILLED if a registered L1 plan exists; pointer-only (plan body lives in the plan file)
  - L2 Context                 HOOK-FILLED if a registered L2 plan exists; pointer-only
  - Key Files                  HOOK-FILLED via project-context resolver, then MODEL-APPENDED for task-specific files
  - Task State                 MODEL-AUTHORED JSON (R4 schema; envelope-versioned)
  - Constraints/Blockers       MODEL-AUTHORED prose (write "None" if empty - V8 rejects empty placeholders)
  - Git State                  HOOK-FILLED from `git log` + `git status`

Section order is research-informed (primacy + recency): goal-anchor first, freshest-state last.
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

<!-- V7 lint: this section must contain at least one file-path-with-line-number reference (e.g., `lib/foo.sh:42`). Vague summaries like "continue the refactor" without specifics are rejected. -->

## Application Context

<<APPLICATION_CONTEXT>>

<!-- Brief project description - what the project does, the cycle's current focus, anything not visible from code or docs but needed by the next session to act safely. Two to four sentences typical. -->

## Position

- Workspace: `<<WORKSPACE_PATH>>`
- Branch: `<<BRANCH>>`
- HEAD: `<<HEAD_SHA>>`
- Phase: <<PHASE>>
- Workstream: `<<WORKSTREAM_ID>>` (display name `<<DISPLAY_NAME>>`)

<!-- V7 lint: `Branch:` and `HEAD:` lines are required. -->

## L1 Context

- Plan: `<<L1_PLAN_PATH>>`
- Current epoch: <<L1_EPOCH>>
- Exit gate: <<L1_EXIT_GATE>>

<!-- Pointer-only. Plan body lives in the plan file; do not duplicate here. If no L1 plan is registered, this entire section is omitted by the hook. -->

## L2 Context

- Plan: `<<L2_PLAN_PATH>>`
- Current step: <<L2_CURRENT_STEP>>

<!-- Pointer-only. Plan body lives in the plan file; do not duplicate here. If no L2 plan is registered, this entire section is omitted by the hook. -->

## Key Files

<<KEY_FILES_MANIFEST>>

<!--
Role-labeled manifest from the project-context resolver. Each row is a role + path + "read if X" hint clause so the next session can route on-demand reads adaptively.

Example rendered rows:
  - **PRD** - `docs/PRD.md` - read if you need product intent or out-of-scope clarifications
  - **Architecture** - `docs/ARCHITECTURE.md` - read if your change touches module boundaries or interfaces
  - **Decisions** - `docs/decisions.md` - read if your change inherits a prior architectural choice

After the resolver-rendered rows, you may append task-specific entries with the same role/path/hint shape.
-->

## Task State

```json
{
  "template_id": "factory",
  "template_version": 1,
  "tasks_done": <<TASKS_DONE_JSON>>,
  "tasks_remaining": <<TASKS_REMAINING_JSON>>
}
```

<!--
Schema (R4):

  tasks_done entries - required: id, description (terse, length ≥20 chars). Optional: commit, l1_step, l2_step, verified_via.
  tasks_remaining entries - required: id, description (terse, length ≥20 chars). Optional: l1_step, l2_step, blocked_by, risk_or_open_question.

Envelope (N5):
  template_id and template_version are required for migration support. Use the integer version of the template file at render time.

Framing principle (§6.R4):
  This JSON exists for delta and in-flight state the plan files do not capture. When plans are solid, expect tasks_done and tasks_remaining to be slim or near-empty. Optional fields are slots for gap-information when gap-information exists - not a checklist to fill.

Per-checkpoint judgment (N1):
  For each prior tasks_done entry, omit it from the new checkpoint if the work is now visible in the code, in a durable artifact, or fully captured by the plan. Omitted entries archive automatically (N2); nothing is deleted.

Empty arrays are valid (`"tasks_done": []`). Do not leave the literal placeholder unfilled - V8 rejects.
-->

## Constraints/Blockers

<<CONSTRAINTS_BLOCKERS>>

<!--
Hard constraints (e.g., do not push, do not delete X, test baselines that must hold) and soft constraints (response style, no timeline framing, deterministic-where-possible).

Write "None" or "No active blockers" if empty - V8 rejects empty placeholders. Bullet list is the convention but prose is acceptable.
-->

## Git State

```
$ git log --oneline -10
<<GIT_LOG>>

$ git status -s
<<GIT_STATUS>>
```

<!-- HOOK-FILLED literal output. Recency anchor - last section by design (primacy+recency: freshest state at the bottom is what the model sees most recently before acting). -->
