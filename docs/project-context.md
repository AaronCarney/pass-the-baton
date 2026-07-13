# Project Context Resolver

Per-project configuration that maps semantic roles (PRD, architecture, decisions, ...) to actual files in your repository. Consumed by the Key Files manifest rendering in `task` and `factory` templates.

Since E7 the resolver is **registry-driven**: an in-code default seed of six built-in roles is MERGED with the `roles` registry in your `project-context.json`. You can override a built-in role or add a brand-new role type of your own, and it surfaces as an injected Key Files pointer **with no code edit**.

## File location

`.baton-project/project-context.json` at your project root. Tracked in git (your team shares the role mapping).

If the file is absent, the resolver falls back to the built-in seed under `convention` strategy.

The path can be overridden via `project_context_file` in `$XDG_CONFIG_HOME/baton/config.json` (exercised by test t6).

## Schema

```json
{
  "version": 1,
  "fallback_strategy": "convention",
  "roles": {
    "prd": "docs/PRD.md",
    "architecture": { "path": "specs/system-architecture.md", "label": "System Design" },
    "runbook": {
      "label": "Runbook",
      "hint": "you need operational runbook steps",
      "path": "ops/RUNBOOK.md",
      "order": 100
    }
  }
}
```

### Top-level fields

| Field | Type | Default | Purpose |
|---|---|---|---|
| `version` | integer | `1` | Schema envelope version. Reserved for future migration. |
| `fallback_strategy` | enum | `"convention"` | `"convention"` falls back to a role's convention path when it has no explicit `path`; `"explicit"` returns no resolution for unconfigured roles. |
| `roles.<name>` | string \| object | (see below) | Registry entry for a role. Merges over the built-in seed. |

### Role entry: string OR object

A `roles.<name>` value may be either form:

- **String** (path override) - shorthand equivalent to `{ "path": "<that string>" }`. This is the pre-E7 schema and keeps working unchanged. The role uses its built-in seed `label` and `hint`.
- **Object** - any subset of these keys; each provided key overrides the seed (or defines a brand-new role):

| Key | Type | Purpose |
|---|---|---|
| `path` | string | Explicit project-root-relative path. Resolves regardless of `fallback_strategy` (when the file exists). |
| `label` | string | Display label in the manifest row. Falls back to the seed label, else the role name (underscores shown as spaces). |
| `hint` | string | The read-if clause. Falls back to the seed hint. If empty and no seed hint exists, the row omits the read-if clause. |
| `convention` | string | Fallback path used only under `fallback_strategy: "convention"` when no `path` resolves. Built-ins seed this; user roles usually set `path` instead. |
| `order` | integer | Sort position in the manifest. Built-ins default to 10-60; user roles without an explicit `order` append after the built-ins in insertion order. |

### Built-in roles (default seed)

| Role | Convention fallback | Read-if hint | Order |
|---|---|---|---|
| `prd` | `docs/PRD.md` | you need product intent or out-of-scope clarifications | 10 |
| `brd` | `docs/BRD.md` | you need business-requirements context | 20 |
| `architecture` | `docs/ARCHITECTURE.md` | your change touches module boundaries or interfaces | 30 |
| `decisions` | `docs/decisions.md` | your change inherits a prior architectural choice | 40 |
| `standards` | (no convention; configure via `path`) | you need workflow / coding standards | 50 |
| `current_plan` | (no convention; configure via `path`) | you need tactical step-by-step for the active L2 plan | 60 |

Adding a role name that is not in this table defines a **new** role; it must carry at least a `path` (and normally a `label`/`hint`).

## How templates consume the resolver

The `task` and `factory` templates contain a `<<KEY_FILES_MANIFEST>>` placeholder. At progress-file render time, the write-trigger hook calls `pc::render_manifest` from `.claude/hooks/lib/project-context.sh` and substitutes the rendered rows.

Each row has the shape:

```
- **<Label>** - `<path>` - read if <hint>
```

Missing files are skipped silently. Task-specific files may be appended after the resolver-rendered rows by the model.

## Examples

### Standard project layout

```json
{
  "version": 1,
  "fallback_strategy": "convention",
  "roles": {}
}
```

With all conventional files present (`docs/PRD.md`, `docs/decisions.md`, etc.), the manifest renders all built-in rows automatically.

### Override a built-in path (string shorthand)

```json
{
  "version": 1,
  "fallback_strategy": "explicit",
  "roles": {
    "prd": "specs/product-spec.md",
    "architecture": "specs/system-architecture.md"
  }
}
```

The resolver uses the configured paths and does NOT fall back to convention for unconfigured roles.

### Add a brand-new role (no code edit)

```json
{
  "version": 1,
  "fallback_strategy": "convention",
  "roles": {
    "runbook": {
      "label": "Runbook",
      "hint": "you need operational runbook steps",
      "path": "ops/RUNBOOK.md"
    },
    "api_contract": {
      "label": "API Contract",
      "hint": "your change touches the public API surface",
      "path": "docs/openapi.yaml",
      "order": 35
    }
  }
}
```

`runbook` appends after the six built-ins; `api_contract` (order 35) sits between `architecture` (30) and `decisions` (40). Neither requires touching `project-context.sh`.

### Empty-string a role (and how to truly exclude)

```json
{
  "version": 1,
  "fallback_strategy": "convention",
  "roles": {
    "prd": ""
  }
}
```

Explicit empty string gives `prd` no resolvable path; under `explicit` it is excluded, and under `convention` it still falls back to its seed convention only if that file exists. To hard-exclude a role regardless of convention, use `fallback_strategy: "explicit"` and omit it.

## Versioning

The `version` integer is the envelope version. Reserved for future migration when the resolver's role set or schema shape evolves. Absent = `1`.
