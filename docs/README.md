# Pass the Baton - Documentation Index

Start at the [project README](../README.md) for the elevator pitch + quick install. This index maps the rest.

## I want to install / set up

- [**install.md**](install.md) - full setup, dependency table (core + analysis tools), platform support, uninstall.
- [**context-baton.md**](context-baton.md) - design rationale, state schema, env-var reference, troubleshooting (jq recipes for state files + event log).

## I want to use the CLI tools

Flag-by-flag reference for `cost.sh`, `doctor.sh`, `baton-dashboard.sh`, and `project.sh` lives in [cli.md](cli.md). The methodology docs below cover the tools that have their own page.

| Tool | Doc |
|---|---|
| `tools/recommend.sh` - which compaction method + threshold % saves you the most | [recommend.md](recommend.md) |
| `tools/project.sh` - mark / list / inspect per-project sessions | [cli.md § project.sh](cli.md#toolsprojectsh) · [projects.md](projects.md) (data model) |
| `tools/time-to-complete-corpus.sh` - corpus-wide time-to-complete analysis | [time-to-complete.md](time-to-complete.md) |
| `tools/cost.sh` / `tools/cost-compare.sh` - per-session cost + threshold-sweep comparison | [cli.md § cost.sh](cli.md#toolscostsh) · [cost-model.md](cost-model.md) (methodology) |
| `tools/query.sh` / `tools/latency.sh` | [telemetry.md](telemetry.md) (event-log schema the queries hit) |
| `tools/doctor.sh` - health probe when something doesn't fire | [cli.md § doctor.sh](cli.md#toolsdoctorsh) · [context-baton.md § Troubleshooting](context-baton.md) |
| `tools/baton-dashboard.sh` - get/set the `/baton` skill config | [cli.md § baton-dashboard.sh](cli.md#toolsbaton-dashboardsh) |

## I want to configure something

- **Trigger threshold (`BATON_PCT_THRESHOLD`)** + the four common opt-in env vars: see [project README § Configuration](../README.md#configuration).
- **Full env-var table** (paths, TTLs, archive dirs): [context-baton.md § Configuration](context-baton.md#configuration-env-vars).
- **Per-project role mapping** (`project-context.json`): [project-context.md](project-context.md).
- **Outcome-quality proxies** (opt-in): [outcome-proxies.md](outcome-proxies.md), plus [install.md § 4](install.md#4-outcome-quality-proxies-opt-in) for the bootstrap workflow.

## I'm integrating with another pipeline

- [**public-api.md**](public-api.md) - stable contracts (state files, hook events, env vars). Read this before depending on anything.
- [**integration-patterns.md**](integration-patterns.md) - three composition patterns (drop-in, multi-workstream, pre-commit gate).
- [**telemetry.md**](telemetry.md) - full event-log schema, CC8 redaction rules, env-var controls.

## I'm contributing code or want to understand mechanism

- **Mechanism overview** - the hook → event → state-write flow + SessionStart routing precedence: [project README § How It Works](../README.md#how-it-works).
- **Repository layout** - full per-file annotated tree: [repo-layout.md](repo-layout.md).
- **Design rationale, state schema, troubleshooting:** [context-baton.md](context-baton.md).
- **Contributing** (scope, style, the test-as-contract rule): [CONTRIBUTING.md](../CONTRIBUTING.md).
