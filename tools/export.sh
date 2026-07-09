#!/usr/bin/env bash
# tools/export.sh - export the baton event log in OpenTelemetry gen_ai.* shape.
# Gated by BATON_OTEL_EXPORT; streams the live JSONL event log through
# otel::rename_line (additive data.* -> gen_ai.* rename, idempotent).
# Reads via eventlog::stream (lib/eventlog.sh) so a torn/zero-filled line drops
# instead of aborting the export mid-stream (CC20 tolerant-read contract).
# Scope: the LIVE log tail only. Rotated .zst shards are out of scope - a
# consumer wanting full history should use query.sh/latency.sh (shard-aware).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/eventlog.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/.claude/hooks/lib/otel_mapping.sh"

usage() { echo "Usage: export.sh --otel" >&2; }

case "${1:-}" in
  --otel) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

GATE="$(_cfg::get BATON_OTEL_EXPORT '')"
if [ -z "$GATE" ]; then
  echo "export: OTel export disabled -- set BATON_OTEL_EXPORT to enable" >&2
  exit 3
fi

LOG="$(_cfg::get BATON_EVENT_LOG "${XDG_STATE_HOME:-$HOME/.local/state}/baton/hook-events.jsonl")"
[ -s "$LOG" ] || exit 0

eventlog::stream "$LOG" | while IFS= read -r line; do
  otel::rename_line "$line"
done
