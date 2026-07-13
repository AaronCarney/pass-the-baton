# Repository Layout

The full annotated file tree. For the high-level directory-role map, see the [project README § Repository Layout](../README.md#repository-layout).

```
.claude/
  hooks/
    context-checkpoint.sh        # PreToolUse - trigger at threshold
    checkpoint-write-trigger.sh  # PostToolUse (Write|Edit|MultiEdit) - save + archive
    session-start.sh             # SessionStart - inject directive
    post-tool-batch.sh           # PostToolBatch - cost telemetry + cache anomaly
    post-subagent-cost.sh        # SubagentStop - subagent cost_rollup (source:"subagent")
    tool-timing.sh               # PostToolUse (all, opt-in) - per-tool latency
    cleanup-on-exit.sh           # SessionEnd - per-session cleanup
    project-detect.sh            # UserPromptSubmit - workstream display_name detection
    outcome-proxy-code-execution.sh  # PostToolUse (Bash, opt-in) - outcome-quality proxy
    outcome-proxy-retry-density.sh   # UserPromptSubmit (opt-in) - retry-density proxy
    lib/
      envelope.sh                # sole writer of the structured telemetry log
                                 #   ($XDG_STATE_HOME/baton/hook-events.jsonl);
                                 #   schema_version=1, redaction, 4 KiB cap.
                                 # Note: workstream-lib.sh::log_event writes a separate
                                 #   project-local forensic log at
                                 #   $BATON_DIR/hook-events.jsonl (same basename,
                                 #   different file). See docs/context-baton.md.
      otel_mapping.sh            # OTel field-name map; sourced by tools/export.sh --otel
      workstream-lib.sh          # shared workstream helpers
      lints.sh                   # progress-file lint pipeline (V1/V7/V8)
      outcome-proxies.sh         # outcome-quality proxy helpers
      project-context.sh         # project-context.json role-mapping
      rolloff.sh                 # progress/workstream archive helpers
      session-start-helpers.sh   # SessionStart resolution helpers
      template-render.sh         # progress-template rendering
      template-resolve.sh        # template name → path resolution
      usage-tokens.sh            # shared 5-field token extractor (cost-rollup hooks)
    tests/                       # shell test suites (see Tests section)
  skills/
    baton/                       # /baton config dashboard
    install-baton/          # install assistant
  settings.json                  # repo-local hook wiring (cost + latency only)
lib/
  cost-models.sh                 # per-model pricing, cost_of_turn
  tokens.sh                      # byte→token estimator
  transcript.sh                  # per-turn token stream reader (redaction-safe)
  cost-compare-model.sh          # economic model (uncached vs cached)
tools/
  install.sh, merge-settings.sh, install-cron.sh, uninstall.sh
  verify-install.sh, restore-workstream.sh
  cleanup-cron.sh, cleanup-cron-wrapper.sh
  doctor.sh                      # health probe (FS type, perms, anomaly count)
  query.sh                       # DuckDB SQL over hook-events.jsonl
  cost.sh                        # per-session cost breakdown
  cost-compare.sh                # threshold-sweep + resume-payoff comparison
  recommend.sh                   # corpus-wide method + threshold recommendation
                                 #   ("which compaction method + % saves you the most")
                                 #   - see docs/recommend.md; needs python deps
  calibrate-bytes-per-token.sh   # model-specific ratio calibration
  latency.sh                     # quantile reporting (per-tool, overhead, summarizer)
assets/
  baton-pct.sh       # statusline percentage helper
share/
  logrotate.d/baton  # daily rotate, 30-day retain, zstd, postrotate guard
docs/
  README.md                      # docs index - find what you need
  architecture.md                # end-to-end data flow: hooks -> libs -> state -> tools
  install.md                     # first-time setup
  cli.md                         # CLI tool reference
  arc.md                         # per-arc cost attribution
  context-baton.md          # design, env vars, state schema, troubleshooting
  configuration.md               # config-file surfaces + env > config.json > default order
  repair-event-log.md            # backup-first event-log repair runbook (NUL/blank lines)
  integration-patterns.md        # 3 patterns for factory integrators
  public-api.md                  # stable contracts (state, hook events, env vars)
  telemetry.md                   # event log schema, env-var controls, redaction rules
  cost-model.md                  # pricing primitives, geo/fast multipliers, calibration
  recommend.md                   # recommend.sh usage + interpretation
  projects.md                    # project.sh CLI + project_boundary event shape
  project-context.md             # project-context.json role-mapping config
  outcome-proxies.md             # opt-in outcome-quality proxy events
  time-to-complete.md            # time-to-complete-corpus.sh analysis tool
.github/workflows/
  baton-tests.yml           # CI
```
