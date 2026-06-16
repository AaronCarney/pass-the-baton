# Project Context Resolver

Per-project configuration that maps semantic roles (PRD, architecture, decisions, ...) to actual files in your repository. Consumed by the Key Files manifest rendering in `task` and `factory` templates.

## File location

`.baton-project/project-context.json` at your project root. Tracked in git (your team shares the role mapping).

If the file is absent, the resolver falls back to the convention list below.

## Schema

```json
{
  "version": 1,
  "roles": {
    "prd": "docs/PRD.md",
    "brd": "docs/BRD.md",
    "architecture": "docs/ARCHITECTURE.md",
    "decisions": "docs/decisions.md",
    "standards": "docs/standards/index.yml",
    "current_plan": "docs/active-plan.json"
  },
  "fallback_strategy": "convention"
}
```

### Fields

| Field | Type | Default | Purpose |
|---|---|---|---|
| `version` | integer | `1` | Schema envelope version. Reserved for future migration. |
| `roles.<name>` | string (path) | (varies - see fallback list) | Project-root-relative path for that role. Null/empty means "use fallback_strategy". |
| `fallback_strategy` | enum | `"convention"` | `"convention"` falls back to the conventional path if no role is configured; `"explicit"` returns no resolution. |

### Built-in roles

| Role | Convention fallback | Read-if hint |
|---|---|---|
| `prd` | `docs/PRD.md` | you need product intent or out-of-scope clarifications |
| `brd` | `docs/BRD.md` | you need business-requirements context |
| `architecture` | `docs/ARCHITECTURE.md` | your change touches module boundaries or interfaces |
| `decisions` | `docs/decisions.md` | your change inherits a prior architectural choice |
| `standards` | (no convention; configurable via the `standards` role) | you need workflow / coding standards |
| `current_plan` | (no convention; must be explicit) | you need tactical step-by-step for the active L2 plan |

Additional roles are reserved for future use; the resolver currently surfaces these six in the Key Files manifest output.

## How templates consume the resolver

The `task` and `factory` templates contain a `<<KEY_FILES_MANIFEST>>` placeholder. At progress-file render time, the write-trigger hook calls `pc::render_manifest` from `.claude/hooks/lib/project-context.sh` and substitutes the rendered rows.

Each row has the shape:

```
- **<Label>** - `<path>` - read if <hint>
```

Missing files are skipped silently (per P4). Task-specific files may be appended after the resolver-rendered rows by the model.

## Examples

### Standard project layout

```json
{
  "version": 1,
  "roles": {},
  "fallback_strategy": "convention"
}
```

With all conventional files present (`docs/PRD.md`, `docs/decisions.md`, etc.), the manifest renders all rows automatically.

### Non-standard layout

```json
{
  "version": 1,
  "roles": {
    "prd": "specs/product-spec.md",
    "architecture": "specs/system-architecture.md",
    "decisions": "specs/decisions/ADR-index.md"
  },
  "fallback_strategy": "explicit"
}
```

The resolver uses the configured paths and does NOT fall back to convention for unconfigured roles. Useful when conventional names would collide or mislead.

### No PRD, BRD-only project

```json
{
  "version": 1,
  "roles": {
    "prd": "",
    "brd": "docs/BRD.md"
  },
  "fallback_strategy": "convention"
}
```

Explicit empty string excludes `prd` from the manifest even if `docs/PRD.md` exists.

## Versioning

The `version` integer is the envelope version. Reserved for future migration when the resolver's role set or schema shape evolves. Absent = `1`.
