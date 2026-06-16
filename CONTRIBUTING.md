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

## The Issue We Watch

[anthropics/claude-code#18417](https://github.com/anthropics/claude-code/issues/18417) asks Anthropic for native percentage-triggered persistence. If that ships, Pass the Baton plans retirement - the wedge zeros out. We monitor this issue as the project's kill-switch trigger. PRs that hedge against this scenario (e.g., easier migration off the tool) are welcome.

## Tests

102 shell test suites under [`.claude/hooks/tests/`](.claude/hooks/tests/), over 1,700 hard asserts. CI runs the full set on push and PR via [`.github/workflows/baton-tests.yml`](.github/workflows/baton-tests.yml).

Run a single suite: `bash .claude/hooks/tests/<suite>.sh`. Run the full set locally: `for t in .claude/hooks/tests/test-*.sh; do bash "$t"; done`.

New code paths must ship with at least one test that exercises the real behavior - not a `exit 0` placeholder. Prefer envelope-emitted fixtures over hand-rolled JSON where the event log is involved (see `test-query.sh` for the pattern). The test suite is the contract: a green run is the precondition for merge.

Prerequisites: `jq`, `flock`, GNU `grep`/`sed`. See [`.claude/hooks/tests/PREREQS.md`](.claude/hooks/tests/PREREQS.md).

## Style

Bash 4+ throughout, `shellcheck`-clean, no new runtime dependencies without discussion. The install pipeline (`tools/install.sh`) and `lib/cost-models.sh` use associative arrays (`declare -A`) so bash 3.2 is not supported anywhere - `install.sh` rejects bash <4 at startup. Hook scripts avoid bash 4-specific features where the readability cost is low, but no compatibility guarantee with 3.2 is made.
