# Contributing

**Scope discipline.** This is a small utility, not a platform. Solo-maintained. Contributions welcome in these shapes:

- Bug fixes for documented behavior.
- Test coverage for existing code paths.
- Doc clarifications.
- Portability fixes (Linux/macOS shell differences).
- New env vars that generalize cleanly within the existing two-tier customization model.

**Not in scope:**

- A plugin system, extension API, or "configurable backend" of any kind.
- Network features of any kind.
- Memory / RAG / vector-store features.
- IDE integrations.
- Cross-machine sync.

If you're not sure whether a contribution fits, open an issue first.

## Public API

See [`docs/public-api.md`](docs/public-api.md) for what's stable and what's internal. Breaking changes to the public API require a major version bump.

## Cutting a Release

[`tools/release-gates.sh`](tools/release-gates.sh) checks the version bump and the changelog section mechanically. It prints `PASS`/`FAIL` per gate and exits 0 only when every gate passed (1 if any gate failed, 2 on a bad invocation). Run it from the repo root before the release lands:

```
bash tools/release-gates.sh --repo . --version <new> --date <cut date> --prior <previous>
```

`--repo` and `--version` are required. `--date` and `--prior` are optional in the argument parser, but pass both: each one tightens a gate from a structural check to an exact-value one.

- `--date` pins the exact date on the `## [<new>] - <date>` heading. Without it, gate 2 only requires some well-formed ISO date, so a date predating the work the release contains passes.
- `--prior` pins the previous release's version on the third `## [` heading. Without it, gate 8 is structural only: it catches a prior heading lost off the end of the file or missing its date, but not one deleted from the middle of the changelog, where the release before it is itself a well-formed dated heading. That case matters because the content gates derive the release section as the lines between its heading and the next `## [`, so a lost prior heading silently swallows the previous release's bullets into this one.

Gates 4, 5 and 6 grade the content of one specific cut and are expected to be edited at each release, not deleted:

- Gate 4 (`pending-note`) asserts one hardcoded `[Unreleased]` note string stayed under `[Unreleased]` and was not folded into the release section. The string is the note that was pending at that cut.
- Gate 5 (`content-coverage`) keys on the areas that release ships, by keyword.
- Gate 6 (`bullet-floor`) sets the minimum bullet count for the release section.

The remaining gates - 0 through 3, 7 and 8 - are structural and carry over unchanged.

## The Issue We Watch

[anthropics/claude-code#18417](https://github.com/anthropics/claude-code/issues/18417) asks Anthropic for native percentage-triggered persistence. Even if it ships, it doesn't obsolete Pass the Baton: the novelty here is multi-terminal safety, terminal-bound state so concurrent Claude Code sessions (same repo or different) never overwrite each other's continuity. Native single-session persistence wouldn't cover that. We track the issue for feature overlap, not as a kill-switch.

## Tests

151 shell test suites under [`.claude/hooks/tests/`](.claude/hooks/tests/), over 1,700 hard asserts. CI runs the full set on push and PR via [`.github/workflows/baton-tests.yml`](.github/workflows/baton-tests.yml).

Run a single suite: `bash .claude/hooks/tests/<suite>.sh`. Run the full set locally: `for t in .claude/hooks/tests/test-*.sh; do bash "$t"; done`.

New code paths must ship with at least one test that exercises the real behavior - not a `exit 0` placeholder. Prefer envelope-emitted fixtures over hand-rolled JSON where the event log is involved (see `test-query.sh` for the pattern). The test suite is the contract: a green run is the precondition for merge.

Prerequisites: `jq`, `flock`, GNU `grep`/`sed`. See [`.claude/hooks/tests/PREREQS.md`](.claude/hooks/tests/PREREQS.md).

## Style

Bash 4+ throughout, `shellcheck`-clean, no new runtime dependencies without discussion. The install pipeline (`tools/install.sh`) and `lib/cost-models.sh` use associative arrays (`declare -A`) so bash 3.2 is not supported anywhere - `install.sh` rejects bash <4 at startup. Hook scripts avoid bash 4-specific features where the readability cost is low, but no compatibility guarantee with 3.2 is made.
