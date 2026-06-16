# Test Prerequisites

The test suite (`test-workstream-hooks.sh`, `test-restore-workstream.sh`) requires:

## System dependencies

- `bash` 4.0+
- `jq` 1.6+
- `flock` (util-linux; on macOS: `brew install util-linux`)
- `find`, `grep`, `md5sum`, `stat`, `date` (GNU coreutils)

## Environment

- No `BATON_DIR`, `BATON_PROJECT_DIR`, or `BATON_ARCHIVE_DIR` set in the outer shell (tests set their own per-invocation).
- No `OLORIN_*` vars set (would trigger deprecation warnings but not failures).
- `/tmp` writable with at least 10 MB free.

## Filesystem state

- Test suite creates isolated tmpdir per test via `mktemp -d`.
- No persistent state left behind (each test `rm -rf`s its proj).
- `/tmp/claude-*` files from previous crashes will not interfere (unique `$$` suffixes per test).

## Running

```bash
bash .claude/hooks/tests/test-workstream-hooks.sh
bash .claude/hooks/tests/test-restore-workstream.sh
```

All suites must exit 0 with 0 failed before merging.

## Python tier (E15+)

- `python3` 3.10+
- numpy, scipy, pymc, matplotlib (install via `pip install -r requirements.txt`)
- pymc only needed for `tools/hierarchical-model.py`; numpy + scipy required for `tools/_stats_bootstrap.py`
