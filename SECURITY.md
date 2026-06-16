# Security Policy

## Reporting a Vulnerability

Email **aaron.l.carney@gmail.com** with a description of the issue. Please do not file public GitHub issues for suspected vulnerabilities until a fix is available.

Expect an acknowledgement within **7 days**. Single-maintainer project; no formal SLA on a fix beyond best-effort.

## Scope

Pass the Baton is primarily a **local** Claude Code observability and progress-file tool. State files (`$BATON_DIR/`), the structured telemetry log (`$XDG_STATE_HOME/baton/hook-events.jsonl`, mode `0600`), and the forensic event log are all local-only - **no telemetry is ever transmitted off-machine**.

The network surface is limited to three explicit, scoped API calls:

| Caller | Endpoint | Purpose | Trigger |
|---|---|---|---|
| `tools/calibrate-bytes-per-token.sh` (via `tools/cost.sh --verify`) | `api.anthropic.com/v1/messages/count_tokens` | Authoritative token counts for the cost-model calibration | Manual: only when the user runs `cost.sh --verify --corpus …` |
| `tools/retry-intent-classify.sh` | `api.anthropic.com/v1/messages` or `api.openai.com/v1/chat/completions` | Classifier over user-supplied retry text (no transcript content) | Manual: only when invoked directly by the user |
| `.claude/hooks/session-start.sh` (prewarm) | `api.anthropic.com/v1/messages` | `max_tokens:0` prompt-cache pre-warm at SessionStart | Opt-in: requires `BATON_PREWARM=1` |

All three are user-initiated or opt-in. None run from the default checkpoint trigger path; none send transcript text, state files, or telemetry. A path-injection or argument-tampering issue in any of the three that caused unintended data egress would be **in scope** for this policy.

### In scope

- Anything that could cause Pass the Baton to write outside its documented paths, leak prompt/completion text into the event logs (the CC8 redaction contract - see [`docs/telemetry.md`](docs/telemetry.md)), or corrupt another tool's state.
- Privilege-escalation or sandbox-escape paths via the installed hooks or `tools/*.sh` scripts.
- Path-traversal, command-injection, or lock-races in any hook, library, or tool under this repo.

### Out of scope

- Vulnerabilities in Claude Code itself (report to Anthropic).
- Vulnerabilities in third-party dependencies (`jq`, `flock`, `duckdb`, etc.) - report upstream; we will track and bump on release.
- Issues that require an already-compromised local account (e.g. an attacker who can write to `~/.claude/settings.json` can already execute arbitrary hooks).
- Vulnerabilities in the upstream Anthropic / OpenAI APIs themselves (the three call sites above are thin clients).
