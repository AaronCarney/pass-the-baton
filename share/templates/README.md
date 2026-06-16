# Progress File Templates

This directory ships three reference templates and documents the contract for user-authored `custom` templates.

## Shipped templates

| Template | When to use | Sections | Active lints |
|---|---|---|---|
| `free.md` | Unstructured Claude Code use; prose-only session notes | Session Directive, What's Next, Constraints/Blockers | V1, V8 |
| `task.md` | Semi-structured project work outside a formal L1/L2 plan | Adds Application Context, Position, Key Files, Task State (markdown checkboxes), Archived, Git State | V1, V7, V8 |
| `factory.md` | Full software-factory workflow with L1/L2 plan awareness | All of `task` plus L1 Context, L2 Context, and JSON Task State (R4 schema) | V1, V7, V8 (incl. JSON-entry sub-lints) |

Each template has a companion `<name>.json` section manifest sidecar that declares required sections, applicable lints, and rolloff convention.

## Placeholder convention

All templates use `<<UPPER_CASE>>` placeholders. The V8 lint rejects any rendered progress file that still contains an unfilled placeholder.

### Hook-filled placeholders

These are substituted by the checkpoint hooks before the model sees the rendered template:

| Placeholder | Source |
|---|---|
| `<<WORKSPACE_PATH>>` | `$CLAUDE_PROJECT_DIR` |
| `<<BRANCH>>` | `git rev-parse --abbrev-ref HEAD` |
| `<<HEAD_SHA>>` | `git rev-parse --short HEAD` |
| `<<PHASE>>` | workstream record `.phase` field |
| `<<WORKSTREAM_ID>>` | workstream record `.workstream` field |
| `<<DISPLAY_NAME>>` | workstream record `.display_name` field |
| `<<L1_PLAN_PATH>>` | workstream record `.l1_plan_path` field |
| `<<L1_EPOCH>>` | workstream record `.l1_epoch` (factory only) |
| `<<L1_EXIT_GATE>>` | workstream record `.l1_exit_gate` (factory only) |
| `<<L2_PLAN_PATH>>` | workstream record `.l2_plan_path` field |
| `<<L2_CURRENT_STEP>>` | workstream record `.l2_current_step` |
| `<<KEY_FILES_MANIFEST>>` | project-context resolver output (role-labeled rows) |
| `<<GIT_LOG>>` | `git log --oneline -10` |
| `<<GIT_STATUS>>` | `git status -s` |
| `<<ARCHIVED_CHECKBOXES>>` (task only) | Auto-populated by write-trigger hook |

### Model-authored placeholders

These are left for the model to fill at checkpoint write time:

| Placeholder | What goes here |
|---|---|
| `<<WHATS_NEXT>>` | Prose. Factory and task templates require ≥1 file:line reference (V7). |
| `<<APPLICATION_CONTEXT>>` | Brief project description; 2-4 sentences typical |
| `<<TASKS_DONE_JSON>>` / `<<TASKS_REMAINING_JSON>>` (factory only) | JSON arrays per R4 schema |
| `<<TASK_STATE_CHECKBOXES>>` (task only) | Markdown checkbox list - `[ ]` pending, `[x]` done |
| `<<CONSTRAINTS_BLOCKERS>>` | Prose. Write "None" if empty (V8 rejects empty placeholders) |

## Custom template contract

A custom template lives at `$XDG_CONFIG_HOME/baton/templates/<name>.md` with a companion `<name>.json` section manifest sidecar. To activate it:

```bash
/baton set template=<name>
```

### Minimum required sections

Custom templates must include at least these two sections (V8 rejects empty placeholders in both):

```markdown
## Session Directive
> [your directive text - V1 will line-diff this verbatim]

## What's Next

<<WHATS_NEXT>>
```

### Section manifest sidecar

The `<name>.json` sidecar declares which sections are required and which lints apply. Schema:

```json
{
  "template_id": "<name>",
  "template_version": 1,
  "required_sections": ["Session Directive", "What's Next"],
  "optional_sections": [],
  "lints": {
    "V1": {"enabled": true, "target": "Session Directive"},
    "V7": {"enabled": false},
    "V8": {"enabled": true, "pattern": "<<[A-Z_]+>>"}
  },
  "rolloff": {"strategy": "none"}
}
```

If V7 is enabled, declare per-section `sub_lints` per the example in `task.json` or `factory.json`.

### Rolloff strategies

| Strategy | Behavior | Used by |
|---|---|---|
| `none` | No automatic rolloff; the model carries everything forward | `free.md` |
| `archive-checkbox` | Move `[x]` items from `source_section` to `target_section` at write time | `task.md` |
| `fresh-judgment` | Model decides per-checkpoint what to carry forward; non-carried entries archive to `archive_dir_template` | `factory.md` |

## Versioning

The `template_version` integer field exists in both the template's section manifest and inside the rendered progress file's JSON envelope (factory only). On read, if a progress file's `template_version` is older than the installed template's, a migration function chain runs before the next session sees the body.

Migration runners are deferred until a real schema break forces one. Current state: `template_version: 1` for all shipped templates; absent in older progress files = treated as `1` (config-loader convention).

## Authoring tips

- The Session Directive is V1 line-diff validated. Once committed to your custom template, don't change the directive wording without bumping `template_version` and adding a migration entry.
- Empty placeholder values (e.g., `<<CONSTRAINTS_BLOCKERS>>` rendered as a literal placeholder string) are V8 lint failures. Write a literal value ("None") rather than leaving the placeholder.
- HTML comments (`<!-- ... -->`) in the template are visible to the model but don't render in standard markdown viewers. Use them for authoring annotations.
- The section order in `required_sections` is informational only; the V7 "required sections present" lint does not enforce order. The render order is determined by the literal template file.
